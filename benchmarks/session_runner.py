"""Synchronized device evidence for persistent, prepared CUDA workers."""

import json
from pathlib import Path
import subprocess
import time
import os
import re
import shlex

from benchmarks.gpu_runner import BUILD, ROOT, command, instrument, prerequisites


REQUEST_PREFIX = "BEND_SESSION_REQUEST "

# Emit after the complete response, on re-entry to the serialized read loop.
# Nested BED1 frames inside operation 4 belong to that same request. No
# protocol messages or device counters are borrowed from another request.
REQUEST_HOOK = r'''
static uint64_t session_id, session_start, session_bangs, session_ns, session_syncs, session_rounds;
static unsigned session_pending, session_nested, session_op;
static void session_finish(void) {
  if (!session_pending || session_nested) return;
  uint64_t elapsed = bend_device_now() - session_start;
  fprintf(stderr, "BEND_SESSION_REQUEST {\"schema\":1,\"request\":%llu,\"operation\":%u,"
    "\"backend\":\"%s\",\"native_request_ns\":%llu,\"bangs\":%llu,\"scheduler_ns\":%llu,"
    "\"syncs\":%llu,\"rounds\":%llu}\n", (unsigned long long)session_id, session_op,
    io_gpu ? "cuda" : "cpu", (unsigned long long)elapsed,
    (unsigned long long)(bend_completed_bangs - session_bangs),
    (unsigned long long)(bend_scheduler_ns - session_ns),
    (unsigned long long)(bend_sync_batches - session_syncs),
    (unsigned long long)(bend_rounds_submitted - session_rounds));
  session_pending = 0;
}
static void session_begin(unsigned version, unsigned op, unsigned count) {
  if (session_nested) { --session_nested; return; }
  if (session_pending) abort();
  ++session_id; session_pending = 1; session_op = version == 1 ? 0 : op;
  session_nested = version == 2 && op == 4 ? count : 0;
  session_bangs = bend_completed_bangs; session_ns = bend_scheduler_ns;
  session_syncs = bend_sync_batches; session_rounds = bend_rounds_submitted;
  session_start = bend_device_now();
}
'''


def instrument_session(source, *, requests=False):
    """The production CUDA entry has exactly three reachable bang sites."""
    matches = list(re.finditer(r"#define BANGS\s+3\b", source))
    if len(matches) != 1 or len(re.findall(r"#define BANGS\b", source)) != 1:
        raise RuntimeError("Review the persistent worker's reachable bangs")
    match = matches[0]
    source = instrument(source[:match.start()] + "#define BANGS 1" + source[match.end():])
    source = source.replace("#define BANGS 1", "#define BANGS 3", 1)
    if requests:
        anchor = "static Term be_request(Env e, uint32_t target_cid) {"
        begins = re.findall(r"    if \(!state\) return term_pak\(CID_[A-Za-z0-9_]+_End, 0\);", source)
        if source.count(anchor) != 1 or len(begins) != 1:
            raise RuntimeError("Review persistent request instrumentation anchors")
        begin = begins[0]
        source = source.replace(anchor, REQUEST_HOOK + "\n" + anchor + "\n    session_finish();")
        source = source.replace(begin, begin + "\n    session_begin(r.version, r.operation, r.query_length);")
    return source


def request_metrics(line, *, request, operation, expected_bangs, device):
    """Exact per-request completion, including zero-work/empty requests."""
    try:
        if not line.startswith(REQUEST_PREFIX):
            raise ValueError("missing prefix")
        values = json.loads(line[len(REQUEST_PREFIX):])
        keys = {"schema", "request", "operation", "backend", "native_request_ns",
                "bangs", "scheduler_ns", "syncs", "rounds"}
        if set(values) != keys or values["backend"] != ("cuda" if device else "cpu"):
            raise ValueError("schema/backend")
        if any(type(v) is not int or v < 0 for k, v in values.items() if k != "backend"):
            raise ValueError("numeric fields")
        if (values["schema"], values["request"], values["operation"]) != (1, request, operation):
            raise ValueError("request identity")
        if type(expected_bangs) is not int or expected_bangs < 0:
            raise ValueError("expected plan")
        if values["bangs"] != expected_bangs or (not device and expected_bangs):
            raise ValueError("wrong bang count/CPU fallback")
        bangs, ns, syncs, rounds = (values[k] for k in ("bangs", "scheduler_ns", "syncs", "rounds"))
        if bangs:
            if not (0 < ns <= values["native_request_ns"] and bangs <= syncs <= rounds <= 64 * syncs):
                raise ValueError("synchronized completion")
        elif ns or syncs or rounds:
            raise ValueError("unexpected device work")
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError(f"Invalid persistent request evidence: {error}") from error
    return values


def wave_plan(count, owners, limit=1024):
    """Public count bound makes the production 65,536-wave fuel sufficient."""
    if (type(count) is not int or not 0 <= count <= 65536 or
            type(owners) is not int or owners < 1 or
            type(limit) is not int or not 1 <= limit <= 1024):
        raise ValueError("Invalid prepared CUDA wave plan")
    width = min(owners, limit)
    return [min(width, count - i) for i in range(0, count, width)]


def native_reference_metrics(line, *, backend, count):
    """Optional Edlib attribution; public and cached U64 remain distinct."""
    prefix = "BEND_EDLIB_NATIVE "
    try:
        if not line.startswith(prefix):
            raise ValueError("missing native reference evidence")
        values = json.loads(line[len(prefix):])
        if set(values) != {"native_api_ns", "count", "word_bits", "backend"}:
            raise ValueError("schema")
        if any(type(values[k]) is not int or values[k] < 0 for k in ("native_api_ns", "count", "word_bits")):
            raise ValueError("numeric fields")
        if (values["backend"], values["count"], values["word_bits"]) != (backend, count, 64):
            raise ValueError("backend, count or word width")
    except (ValueError, TypeError, KeyError) as error:
        raise RuntimeError(f"Invalid native reference metrics: {error}") from error
    return values


def validate_native_cuda(sample, count, owners):
    """Keep the separate native probe as strict as public session evidence."""
    from benchmarks import gates as G
    expected = len(wave_plan(count, owners))
    G.check_device(sample, bool(expected))
    if sample.get("device_completed_bangs", 0) != expected:
        raise RuntimeError("Native CUDA completion differs from the exact wave plan")


class RequestEvidence:
    """Read the worker's existing diagnostic file outside the timed boundary."""
    def __init__(self, worker):
        self.worker, self.offset, self.request = worker, 0, 0

    def read(self, operation, expected_bangs, *, device=True, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            raw = os.pread(self.worker._stderr.fileno(), 65536, self.offset)
            end = raw.find(b"\n")
            if end >= 0:
                line = raw[:end].decode("utf-8", errors="strict")
                self.offset += end + 1
                self.request += 1
                return request_metrics(line, request=self.request, operation=operation,
                                       expected_bangs=expected_bangs, device=device)
            if len(raw) == 65536 or time.monotonic() >= deadline or self.worker.process.poll() is not None:
                self.worker.close()
                raise RuntimeError("Missing complete persistent request evidence")
            time.sleep(0.001)


def build_session_variant(root, directory, *, cc=None, owners=1024, wave=1024,
                          grouping="current", requests=True, cuda=True, evidence=True):
    """Freeze production sources/adapters; tuning applies only to that snapshot.

    CUDA is explicit. A separate worker.bend build retains the CPU no-bang
    scheduler. Variant parameters are experiments, never protocol extensions.
    """
    from benchmarks import gates as G
    from benchmarks.production_gate import load_adapter
    from bend_runtime import reproducible_env
    if type(owners) is not int or not 1 <= owners <= 4096:
        raise ValueError("owners must be between 1 and 4096")
    wave_plan(0, owners, wave)
    if grouping not in ("current", "contiguous"):
        raise ValueError("Unknown CUDA grouping")
    if not cuda and (owners != 1024 or wave != 1024 or grouping != "current" or evidence):
        raise ValueError("CPU-only build uses unchanged production worker and no device evidence")
    directory = Path(directory)
    hashes = G.snapshot(Path(root), directory / "source")
    source_root = directory / "source"
    if cuda:
        path = source_root / "GpuBatch.bend"
        text = path.read_text()
        for old, new in [
            ("  P.prepare(query, pairs)", f"  P.prepare_with_max({owners}n, query, pairs)" if owners != 1024 else "  P.prepare(query, pairs)"),
            ("Nat.min(1024n, shards)", f"Nat.min({wave}n, shards)"),
            ("P.ready.inspected(P.Pool{owners, shards, length, budget}, head)",
             "P.ready.jobs(P.Pool{owners, shards, length, budget}, head, True{})" if grouping == "contiguous" else
             "P.ready.inspected(P.Pool{owners, shards, length, budget}, head)")]:
            if text.count(old) != 1:
                raise RuntimeError("Review prepared CUDA tuning substitution")
            text = text.replace(old, new)
        path.write_text(text)
        hashes["GpuBatch.bend"] = G.digest(path.read_bytes())
    cc = cc or shlex.split(os.environ.get("CC", str(ROOT / "scripts/cc")))
    bend = ROOT / "build/tools/bend/bin/bend"
    if command([bend, "version"]) != "bend " + (Path(root) / ".bend-version").read_text().strip():
        raise RuntimeError("Unexpected Bend compiler")
    source, binary = directory / "session.c", directory / "session"
    emit = [bend, source_root / ("gpu_batch.bend" if cuda else "worker.bend"), "-o", source]
    started = time.monotonic_ns()
    command(emit)
    emission_ns = time.monotonic_ns() - started
    if evidence:
        source.write_text(instrument_session(source.read_text(), requests=requests))
    argv = [*cc, "-std=c2x", "-O3", "-pthread", source, "-lm", "-o", binary]
    if cuda:
        toolkit, _, problems = prerequisites(cc)
        if problems:
            raise RuntimeError("; ".join(problems))
        library = toolkit / ("lib64" if (toolkit / "lib64").is_dir() else "lib")
        argv += ["-DBEND_CUDA=1", "-I", toolkit / "include", "-L", library,
                 f"-Wl,-rpath,{library}", "-lcuda", "-lnvrtc"]
    started = time.monotonic_ns()
    command(argv)
    compile_ns = time.monotonic_ns() - started
    trace = subprocess.run(list(map(str, [*argv, "-###"])), capture_output=True,
                           text=True, timeout=30, env=reproducible_env(), check=True)
    adapter, adapter_meta = load_adapter(Path(root), directory / "adapter")
    metadata = {"sources_sha256": hashes, "adapter": adapter_meta,
        "emission_ns": emission_ns, "host_compile_ns": compile_ns,
        "commands": [list(map(str, a)) for a in (emit, argv)],
        "host_driver_trace": trace.stdout + trace.stderr,
        "binary_sha256": G.digest(binary.read_bytes()), "emitted_c_sha256": G.digest(source.read_bytes()),
        "requested_owners": owners if cuda else None, "wave_limit": wave if cuda else None,
        "grouping": grouping if cuda else None, "completion_evidence": evidence,
        "request_evidence": requests and evidence, "backend_build": "cuda" if cuda else "cpu-only"}
    if cuda:
        from benchmarks.gpu_runner import require_gpu_build
        started = time.monotonic_ns()
        metadata["device_program"] = require_gpu_build(binary)
        metadata["device_build_process_ns"] = time.monotonic_ns() - started
    return binary, adapter, metadata


def paired_sessions(factories, workload, expected, *, warmups=3, repeats=20, validate=None):
    """Alternate complete service groups in independent retained workers.

    Factories return production_gate.Service instances. Only diagnostic-file
    reading and independent result validation are outside the Python boundary.
    The caller controls affinity and must finish all builds before calling.
    """
    from benchmarks import gates as G
    from dataclasses import replace
    if warmups < 0 or repeats < 1 or len(factories) != 2:
        raise ValueError("Two variants and positive samples are required")
    sessions, records = {}, {}
    validate = validate or G.validate
    batches = workload.batches or (workload.jobs,)
    if len(expected) != len(batches):
        raise ValueError("Missing independent expected batches")
    try:
        for name, factory in factories.items():
            sessions[name] = factory()
            records[name] = {"setup": sessions[name].setup, "samples": [], "first_alignment_ns": None}
        for repetition in range(-warmups, repeats):
            order = list(factories)
            if repetition % 2:
                order.reverse()
            for position, name in enumerate(order):
                service, record = sessions[name], records[name]
                preparation = service.begin_group()
                if hasattr(service, "group_evidence"):
                    service.group_evidence()
                times, evidence, hashes = [], [], []
                for call in range(workload.reuse_count):
                    index = ((repetition + warmups) * workload.reuse_count + call) % len(batches)
                    jobs = batches[index]
                    started = time.monotonic_ns()
                    values = service.call(jobs)
                    elapsed = time.monotonic_ns() - started
                    if record["first_alignment_ns"] is None:
                        record["first_alignment_ns"] = elapsed
                    times.append(elapsed)
                    if hasattr(service, "completion"):
                        evidence.append(service.completion(len(jobs)))
                    validate(values, expected[index], replace(workload, jobs=jobs))
                    hashes.append(G.digest(json.dumps([v.to_edlib() for v in values], sort_keys=True).encode()))
                charge = service.worker.retained_bytes
                release = service.end_group()
                if hasattr(service, "release_evidence"):
                    service.release_evidence()
                if repetition >= 0:
                    total = sum(times)
                    sample = {"repetition": repetition, "order": position, "call_ns": total,
                        "alignment_calls": [{"index": i, "elapsed_ns": n} for i, n in enumerate(times)], "first_call_in_group_ns": times[0],
                        "repeated_calls_ns": sum(times[1:]), "prepare_pool_service_ns": preparation,
                        "release_service_ns": release, "total_with_prepare_ns": preparation + total,
                        "lifecycle_ns": preparation + total + release, "completion": evidence,
                        "prepared_group_budget_bytes": charge, "output_sha256": hashes,
                        "preparation_lifetime": "fresh group" if service.fresh else "one-time retained setup; reused attribution",
                        "release_lifetime": "fresh group" if service.fresh else "excluded until session close"}
                    if workload.jobs:
                        sample["amortized_per_target_ns"] = (preparation + total) / (len(workload.jobs) * workload.reuse_count)
                    record["samples"].append(sample)
        return records
    finally:
        for name, service in sessions.items():
            service.close()
            if not service.fresh:
                # Retained groups share one setup/release observation. Fresh
                # groups measure both anew. Identify this dependence explicitly.
                release = service.setup.get("release_service_ns", 0)
                for sample in records[name]["samples"]:
                    sample["release_service_ns"] = release
                    sample["lifecycle_ns"] = sample["total_with_prepare_ns"] + release
                    sample["release_lifetime"] = "one-time retained release; reused attribution"


def cuda_service(binary, adapter, workload, threads, retained_owners, *, wave=1024,
                 gpu="1GB", timeout=120, fresh=False):
    """Public prepared String 2/5 route with exact per-request CUDA evidence.

    retained_owners must come from the identical production preparation
    diagnostic, not from the requested maximum. No device occupancy is inferred.
    """
    from benchmarks.production_gate import Service

    class CudaService(Service):
        def __init__(self):
            super().__init__(binary, "compatible-worker-batch", workload, threads, 1, timeout,
                             gpu=gpu, cuda_entry=True, adapter=adapter, fresh=fresh)
            self.evidence = RequestEvidence(self.worker)
            for op in ([1, 3] if fresh else [1, 3, 1]):
                self.evidence.read(op, 0, device=gpu != "off", timeout=timeout)
            self.setup.update(retained_owners=retained_owners, wave_limit=wave,
                              backend="cuda" if gpu != "off" else "gpu-entry-cpu",
                              protocol="BED2 prepared String operations 2/5")

        def group_evidence(self):
            if self.fresh:
                self.evidence.read(1, 0, device=gpu != "off", timeout=timeout)

        def release_evidence(self):
            if self.fresh:
                self.evidence.read(3, 0, device=gpu != "off", timeout=timeout)

        def completion(self, count):
            plan = wave_plan(count, retained_owners, wave)
            sample = self.evidence.read(5, len(plan) if gpu != "off" else 0,
                                        device=gpu != "off", timeout=timeout)
            sample.update(targets_per_wave=plan, expected_active_plan_leaves_per_wave=plan,
                          retained_owners=retained_owners, runtime_host_threads=threads,
                          plan_boundary="Retained count observed independently; leaf counts follow the one-target/owner invariant, not occupancy measurements")
            return sample

        def close(self):
            # Release the public handle before closing the diagnostic file.
            if self.worker.closed:
                return
            if self.owner is not None and not self.owner.released:
                started = time.monotonic_ns()
                self.worker.release_prepared(self.owner, timeout=timeout)
                self.setup["release_service_ns"] = time.monotonic_ns() - started
                self.evidence.read(3, 0, device=gpu != "off", timeout=timeout)
                if self.worker.retained_bytes or self.worker.retained_entries:
                    raise RuntimeError("CUDA public release left retained accounting")
                self.setup["after_release_retained_budget_bytes"] = 0
            self.worker.close()

    return CudaService()


def build_session_probe(cc=None, *, requests=True):
    cc = cc or shlex.split(os.environ.get("CC", str(ROOT / "scripts/cc")))
    source = BUILD / "session.c"
    binary = BUILD / "gpu-session"
    command(["bend", ROOT / "gpu_batch.bend", "-o", source])
    text = source.read_text()
    text = instrument_session(text, requests=requests)
    text += r'''
#if !BEND_RTC && !defined(__METAL_VERSION__)
__attribute__((destructor)) static void session_metrics(void) {
  fprintf(stderr, "BEND_SESSION_METRICS {\"bangs\":%llu,\"scheduler_ns\":%llu,"
    "\"syncs\":%llu,\"rounds\":%llu,\"baseline_bytes\":%llu,\"peak_bytes\":%llu}\n",
    (unsigned long long)bend_completed_bangs, (unsigned long long)bend_scheduler_ns,
    (unsigned long long)bend_sync_batches, (unsigned long long)bend_rounds_submitted,
    (unsigned long long)bend_device_used_baseline, (unsigned long long)bend_device_used_peak);
}
#endif
'''
    source.write_text(text)
    cuda, _, problems = prerequisites(cc)
    if problems:
        raise RuntimeError("; ".join(problems))
    library = cuda / ("lib64" if (cuda / "lib64").is_dir() else "lib")
    command([*cc, "-std=c2x", "-O3", "-pthread", source, "-lm", "-o", binary,
             "-DBEND_CUDA=1", "-I", cuda / "include", "-L", library,
             f"-Wl,-rpath,{library}", "-lcuda", "-lnvrtc"])
    return binary


def session_metrics(stderr, expected_bangs):
    prefix = "BEND_SESSION_METRICS "
    lines = [line[len(prefix):] for line in stderr.splitlines() if line.startswith(prefix)]
    if len(lines) != 1:
        raise RuntimeError(f"Missing persistent-device evidence: {stderr}")
    values = json.loads(lines[0])
    assert all(type(v) is int and v >= 0 for v in values.values()), values
    assert values["bangs"] == expected_bangs > 0, values
    assert values["scheduler_ns"] > 0, values
    assert expected_bangs <= values["syncs"] <= values["rounds"] <= 64 * values["syncs"], values
    assert values["peak_bytes"] >= values["baseline_bytes"] > 0, values
    return values


def observe_owners(api_binary, workload, requested, *, threads=1, timeout=120):
    """Untimed production Pool.prepared observation using the same input."""
    from benchmarks.production_gate import Native
    probe = Native(api_binary, 'string-batch', workload, threads, requested, timeout, 0)
    try:
        return probe.setup
    finally:
        probe.close()


def paired_native(factories, workload, expected, *, warmups=3, repeats=20):
    """Separate native attribution: input conversion and writing excluded.

    Each endpoint returns (complete results, native API metrics). Endpoints
    retain their stated query preparation; primary acceptance uses services.
    """
    from benchmarks import gates as G
    from dataclasses import replace
    if len(factories) != 2 or warmups < 0 or repeats < 1:
        raise ValueError("Two native endpoints and positive samples required")
    sessions, records = {}, {}
    batches = workload.batches or (workload.jobs,)
    try:
        for name, factory in factories.items():
            sessions[name] = factory()
            records[name] = {"setup": sessions[name].setup, "samples": []}
        for repetition in range(-warmups, repeats):
            order = list(factories)
            if repetition % 2:
                order.reverse()
            index = (repetition + warmups) % len(batches)
            for position, name in enumerate(order):
                values, sample = sessions[name].call(batches[index])
                elapsed = sample.get("native_api_ns")
                if type(elapsed) is not int or elapsed < 0:
                    raise RuntimeError("Missing native API boundary")
                G.validate(values, expected[index], replace(workload, jobs=batches[index]))
                if repetition >= 0:
                    records[name]["samples"].append({**sample, "repetition": repetition, "order": position})
        return records
    finally:
        for service in sessions.values():
            service.close()


def main(argv=None):
    """Retained/fresh public sessions within the existing paired gate format."""
    import argparse
    from dataclasses import replace
    from benchmarks import gates as G
    from benchmarks.production_gate import Service, build_references
    from benchmarks.production_workloads import family
    from benchmarks.runner import summarize
    from bend_runtime import configure_toolchain
    from transport import AlignmentWorker, encode_request
    configure_toolchain(ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, default=ROOT)
    parser.add_argument('--candidate', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--owners', type=int, default=1024, help='Candidate requested maximum; not retained owners')
    parser.add_argument('--wave', type=int, default=1024)
    parser.add_argument('--grouping', choices=['current', 'contiguous'], default='current')
    parser.add_argument('--family', action='append', default=[], help='Maintained production family NAME:LENGTH')
    parser.add_argument('--batch-sizes', type=int, nargs='+', default=[8, 128, 1025])
    parser.add_argument('--threads', type=int, nargs='+', choices=[1, 2, 4], default=[1, 2, 4])
    parser.add_argument('--warmups', type=int, default=3)
    parser.add_argument('--repeats', type=int, default=20)
    parser.add_argument('--reuse', type=int, default=1)
    parser.add_argument('--seed', type=int, default=831)
    parser.add_argument('--fresh-prepared', action='store_true')
    parser.add_argument('--heap', default='1GB')
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args(argv)
    if args.warmups < 0 or args.repeats < 1 or args.reuse < 1:
        parser.error('Invalid warmup/repeat/reuse counts')
    for count in args.batch_sizes:
        wave_plan(count, args.owners, args.wave)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    cc = shlex.split(os.environ['CC'])
    builds, variants = {}, {}
    for name, root, options in [('baseline', args.baseline, {}),
            ('candidate', args.candidate, dict(owners=args.owners, wave=args.wave, grouping=args.grouping)),
            ('cpu', args.baseline, dict(cuda=False, evidence=False))]:
        binary, adapter, meta = build_session_variant(root, output / 'builds' / name, cc=cc, **options)
        variants[name] = (binary, adapter)
        builds[name] = meta
    api, builds['api'] = G.build(args.baseline, output / 'builds/api',
        ROOT / 'build/tools/bend/bin/bend', cc, ['-std=c2x', '-O3', '-pthread'],
        entry_name='benchmarks/production_api.bend')
    refs, builds['edlib'] = build_references(output / 'builds/edlib',
        shlex.split(os.environ.get('CXX', 'g++')), '-O3')
    suite = []
    for definition in args.family or ['one:129', 'dna-random:129']:
        name, length = definition.rsplit(':', 1)
        for count in args.batch_sizes:
            query, config, batches = family(name, int(length), count, args.seed)
            suite.append(G.Workload(f'{definition}/{count}', batches[0], batches=batches,
                prepared_query=(query, config), reuse_count=args.reuse, seed=args.seed))
    cpus = G.physical_cpus(os.sched_getaffinity(0))
    if len(cpus) < max(args.threads):
        raise RuntimeError('Insufficient physical host cores')
    document = {'schema': 1, 'records': [], 'builds': builds, 'references': [],
        'warmups': args.warmups, 'repeats': args.repeats, 'affinity': cpus,
        'boundary': 'Complete Python prepared service. Preparation includes cloning once. Evidence and independent validation outside call_ns.',
        'native_boundary': 'Raw request decoded, before Bend String conversion, to re-entry at next serialized read after complete output flush. Includes planning, scheduler, demand migration, materialization and writing; excludes Python and initial raw read.',
        'unmeasured_stages': ['implicit migration time/bytes', 'pure kernel time', 'per-stage host traversal', 'live device allocation lifetimes'],
        'inputs': {G.digest(encode_request(*j)): encode_request(*j).hex() for w in suite for batch in w.batches for j in batch}}
    (output / 'inputs.json').write_text(json.dumps(document['inputs']))
    with AlignmentWorker([refs['oracle'], '--worker']) as oracle:
        for w in suite:
            expected = [[oracle.align(*j, timeout=args.timeout) for j in batch] for batch in w.batches]
            observed = {name: observe_owners(api, w, maximum, timeout=args.timeout)['effective_owners']
                        for name, maximum in [('baseline', 1024), ('candidate', args.owners)]}
            for threads in args.threads:
                with G.affinity(cpus[:threads]):
                    def cuda(name):
                        binary, adapter = variants[name]
                        return cuda_service(binary, adapter, w, threads, observed[name],
                            wave=args.wave if name == 'candidate' else 1024,
                            gpu=args.heap, timeout=args.timeout, fresh=args.fresh_prepared)
                    def cpu(mode):
                        binary, adapter = variants['cpu']
                        return Service(binary, mode, w, threads, threads, args.timeout,
                                       adapter=adapter, fresh=args.fresh_prepared)
                    pairs = [('cuda-policy', lambda: cuda('baseline'), lambda: cuda('candidate')),
                             ('cpu-compatible', lambda: cpu('compatible-worker-batch'), lambda: cuda('candidate')),
                             ('cpu-ordinary', lambda: cpu('ordinary-worker-batch'), lambda: cuda('candidate'))]
                    if w.jobs:
                        q, c = w.prepared_query
                        if q and len(q) <= 65536 and all(j[1] for b in w.batches for j in b) and c == type(c)():
                            pairs.append(('cpu-owned', lambda: cpu('owned-worker-batch'), lambda: cuda('candidate')))
                    if w.prepared_query[1].mode.value == 'NW' and w.prepared_query[1].task.value == 'DISTANCE':
                        for name in ('public', 'cached'):
                            pairs.append(('edlib-' + name, lambda name=name: Service(refs[name],
                                'compatible-worker-batch', w, threads, threads, args.timeout,
                                reference=True, fresh=args.fresh_prepared), lambda: cuda('candidate')))
                    for mode, baseline, candidate in pairs:
                        result = paired_sessions({'baseline': baseline, 'candidate': candidate}, w, expected,
                                                 warmups=args.warmups, repeats=args.repeats)
                        for name, record in result.items():
                            record.update(workload=w.name, variant=name, mode=mode, lifetime='fresh-prepared' if args.fresh_prepared else 'retained-prepared',
                                backend='cuda-service-comparison', threads=threads, batch_size=len(w.jobs),
                                summary=summarize(record['samples']))
                            document['records'].append(record)
                        document['comparisons'] = G.paired_gate(document['records'], 1.0, ['call_ns', 'lifecycle_ns'])
                        G.write_results(output, document)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
