"""Production boundaries for the paired gate; no alternative CLI/report pipeline."""

from contextlib import ExitStack
from dataclasses import replace
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time
from unittest.mock import patch

import transport as wire

from alignment import AlignConfig, CigarFormat, MaxDistance, Mode, Task
from bend_runtime import reproducible_env, runtime_prefix
from transport import AlignmentWorker, LENGTH, REQUEST, encode_request, sequence_bytes
from benchmarks import gates as G
from benchmarks.runner import summarize

API_MODES = {"string-single", "string-batch", "string-serial-batch", "string-diagnostic", "search-diagnostic", "prepare-batch", "prepare-clone", "profile-only"}
CORE_MODES = {"batch", "phases", "prepared", "ordinary-single"}
DEFAULT_MODES = ("ordinary-single", "batch", "string-single", "string-batch", "string-serial-batch",
                 "ordinary-worker-single", "ordinary-worker-batch", "owned-worker-single",
                 "owned-worker-batch", "compatible-worker-single", "compatible-worker-batch")


def executable(command):
    path = Path(shutil.which(str(command)) or command).resolve()
    return {"path": str(path), "sha256": G.digest(path.read_bytes()),
            "version": G.run_command([path, "--version"])}


def provenance(args, cc, cxx, compilers):
    wrapper = G.ROOT / "scripts/cc"
    lean = G.ROOT / "build/tools/lean/bin/lean"
    roots = {}
    for name, root in (("baseline", args.baseline), ("candidate", args.candidate)):
        root = root.resolve()
        roots[name] = {"path": str(root), "commit": G.run_command(["git", "-C", root, "rev-parse", "HEAD"]),
            "status": G.run_command(["git", "-C", root, "status", "--porcelain", "--untracked-files=normal"]),
            "diff_sha256": G.digest(G.run_command(["git", "-C", root, "diff", "HEAD"]).encode())}
    return {"roots": roots, "cc": executable(cc[0]), "cxx": executable(cxx[0]),
        **({"bend": compilers["baseline"]} if compilers["baseline"]["path"] == compilers["candidate"]["path"] else {}),
        "underlying_cc": executable(os.environ.get("BEND_CC", "clang-19")) if Path(cc[0]).resolve() == wrapper.resolve() else executable(cc[0]),
        "wrapper": {"path": str(wrapper), "content": wrapper.read_text(), "sha256": G.digest(wrapper.read_bytes())},
        "bend_compilers": compilers,
        "lean": executable(lean) if lean.exists() else {"status": "unavailable", "pin": (G.ROOT / ".lean-version").read_text().strip()},
        "edlib_gitlink": G.run_command(["git", "ls-tree", "HEAD", "vendor/edlib"]),
        "edlib_head": G.run_command(["git", "-C", G.ROOT / "vendor/edlib", "rev-parse", "HEAD"]),
        "edlib_status": G.run_command(["git", "-C", G.ROOT / "vendor/edlib", "status", "--porcelain"]),
        "environment": {k: os.environ.get(k) for k in ("CC", "BEND_CC", "CXX", "CFLAGS", "CXXFLAGS", "BENDRTS", "CUDA_HOME", "PATH")},
        "effective_runtime_environment": {k: reproducible_env()[k] for k in ("BENDRTS", "BEND_NO_TELEMETRY")},
        "driver_sha256": {str(p.relative_to(G.ROOT)): G.digest(p.read_bytes()) for p in
            [G.ROOT / "run_benchmarks.py", G.ROOT / "bend_runtime.py", G.ROOT / "transport.py", G.ROOT / "alignment.py",
             G.ROOT / "tests/edlib_oracle.cpp", G.ROOT / "src/transport.c",
             *sorted((G.ROOT / "benchmarks").glob("*.py")), *sorted((G.ROOT / "benchmarks").glob("*.cpp")),
             *sorted((G.ROOT / "benchmarks").glob("*.c"))]},
        "edlib_sources_sha256": {str(p.relative_to(G.ROOT)): G.digest(p.read_bytes()) for p in
            (G.ROOT / "vendor/edlib/edlib/src/edlib.cpp", G.ROOT / "vendor/edlib/edlib/include/edlib.h")}}


class ObservedWorker(AlignmentWorker):
    """Diagnostic only. The timed process uses the unmodified Python adapter."""
    def __init__(self, *args, **kwargs):
        self.operations, self.controls = [], []
        self.first_write_ns = None
        self.codec_samples = []
        super().__init__(*args, **kwargs)

    def _write(self, frame, deadline):
        if self.first_write_ns is None:
            self.first_write_ns = time.monotonic_ns()
        offset = 0
        while offset < len(frame):
            size = LENGTH.unpack_from(frame, offset)[0]
            header = REQUEST.unpack_from(frame, offset + 4)
            magic, _, _, _, op, *_ = header
            self.operations.append(op if magic == b"BED2" else "BED1")
            offset += size + 4
            if magic == b"BED2" and op == 4:
                # BED1 jobs following an operation-4 header are its body, not
                # independently dispatched ordinary-single requests.
                for _ in range(header[6]):
                    offset += LENGTH.unpack_from(frame, offset)[0] + 4
        return super()._write(frame, deadline)

    def _control_payload(self, frame, operation):
        value = super()._control_payload(frame, operation)
        self.controls.append({"operation": operation, "status": value[0], "handle_or_width": value[1],
                              "retained_budget_bytes": value[2], "count_or_limit": value[3]})
        return value


def route_evidence(mode, operations, controls):
    suffix = "single" if mode.endswith("single") else "batch"
    wanted = (6 if suffix == "single" else 7) if mode.startswith("owned") else (
        (2 if suffix == "single" else 5) if mode.startswith("compatible") else
        ("BED1" if suffix == "single" else 4))
    executed = [op for op in operations if op not in (1, 3, 8)]
    if not executed or any(op != wanted for op in executed):
        raise RuntimeError(f"Specialization fallback or wrong route: requested {mode}, observed {executed}")
    if any(c["status"] for c in controls if c["operation"] in (6, 7)):
        raise RuntimeError("Owned specialization was rejected")
    capabilities = next((c for c in controls if c["operation"] == 8), None)
    return {"requested_route": mode, "executed_operations": executed, "controls": controls,
            "negotiated_capabilities": capabilities, "actual_route": str(wanted),
            "observation": "separate untimed process using identical binary/inputs/configuration"}


def memory(pid):
    data = Path(f"/proc/{pid}/status").read_text().splitlines()
    values = {line.split(':')[0]: int(line.split()[1]) for line in data if line.startswith(("VmRSS:", "VmHWM:"))}
    details = {line.split(':', 1)[0]: line.split(':', 1)[1].strip() for line in data if ':' in line}
    return {"rss_kib": values.get("VmRSS", 0), "peak_rss_kib": values.get("VmHWM", 0),
            "os_threads": int(details["Threads"]), "os_cpus_allowed": details["Cpus_allowed_list"]}


def prepared_definition(w):
    if w.prepared_query is not None:
        query, config = w.prepared_query
    elif w.jobs:
        query, _, config = w.jobs[0]
    else:
        query, config = b"", AlignConfig()
    query = sequence_bytes(query)
    for batch in w.batches or (w.jobs,):
        if any(sequence_bytes(q) != query or c != config for q, _, c in batch):
            raise ValueError("Prepared production paths require one fixed query/config")
    return query, config


def applicable(mode, w):
    if mode == "profile-only" and w.jobs:
        return "profile-only requires a nonempty query and no targets"
    if mode.endswith("single") and len(w.jobs) != 1:
        return "single API requires exactly one target"
    if mode == "prepared":
        try:
            G.validate_prepared(w.jobs)
        except ValueError as error:
            return str(error)
    elif mode not in CORE_MODES and not mode.startswith("ordinary"):
        try:
            q, c = prepared_definition(w)
        except ValueError as error:
            return str(error)
        if mode == "profile-only" and not q:
            return "profile-only requires a nonempty query and no targets"
        if mode.startswith("owned") and (not q or len(q) > 65536 or c.mode != Mode.NW or c.task != Task.DISTANCE or c.threshold.to_edlib() >= 0):
            return "owned CPU contract requires nonempty query <=65536, unlimited NW DISTANCE"
    return None


class Service:
    def __init__(self, binary, mode, w, thread, shards, timeout, *, reference=False, observed=False, fresh=False):
        self.mode, self.timeout = mode, timeout
        self.fresh = fresh and not mode.startswith("ordinary")
        self.query, self.config = prepared_definition(w) if not mode.startswith("ordinary") else (None, None)
        argv = [binary, str(thread)] if reference else [binary, *runtime_prefix(threads=thread, gpu="off"), "--worker", "--shards", str(shards)]
        cls = ObservedWorker if observed else AlignmentWorker
        started = time.monotonic_ns()
        self.worker = cls(argv, cwd=G.ROOT)
        self.owner = None
        try:
            # Startup control includes process readiness and a complete round trip.
            # Empty query preparation/release is excluded from real preparation.
            with self.worker.prepare(b"", timeout=timeout):
                pass
            self.startup = time.monotonic_ns() - started
            if mode.startswith("compatible") or reference:
                self.worker._owned_supported = {6: False, 7: False}
            started = time.monotonic_ns()
            if self.query is not None and not self.fresh:
                self.owner = self.worker.prepare(self.query, self.config.equalities, timeout=timeout)
            self.setup = {"prepare_pool_service_ns": time.monotonic_ns() - started if self.owner else 0,
                          "startup_control_ns": self.startup, "retained_budget_bytes": self.worker.retained_bytes,
                          "command": list(map(str, argv))}
            # Capability negotiation belongs to diagnostic/setup, not warm timed calls.
            if mode.startswith("owned"):
                from transport import encode_control
                self.worker._exchange(encode_control(8, config=AlignConfig(threshold=MaxDistance(0), cigar_format=CigarFormat.STANDARD)),
                                      lambda d: self.worker._owned_capabilities(d), timeout)
        except BaseException:
            self.worker.close()
            raise

    def _call(self, jobs):
        if self.mode.startswith("ordinary"):
            return [self.worker.align(*jobs[0], timeout=self.timeout)] if self.mode.endswith("single") else self.worker.align_batch(jobs, timeout=self.timeout)
        targets = [j[1] for j in jobs]
        return [self.owner.align(targets[0], self.config, timeout=self.timeout)] if self.mode.endswith("single") else self.owner.align_batch(targets, self.config, timeout=self.timeout)

    def begin_group(self):
        if not self.fresh:
            return self.setup.get("prepare_pool_service_ns", 0)
        started = time.monotonic_ns()
        self.owner = self.worker.prepare(self.query, self.config.equalities, timeout=self.timeout)
        self.group_bytes = self.worker.retained_bytes
        return time.monotonic_ns() - started

    def end_group(self):
        if not self.fresh:
            return 0
        if self.worker.retained_bytes != self.group_bytes:
            raise RuntimeError("Prepared accounting changed during reuse")
        started = time.monotonic_ns()
        self.worker.release_prepared(self.owner, timeout=self.timeout)
        elapsed = time.monotonic_ns() - started
        if self.worker.retained_bytes or self.worker.retained_entries:
            raise RuntimeError("Fresh lifecycle did not release every retained owner")
        return elapsed

    def call(self, jobs):
        if not isinstance(self.worker, ObservedWorker):
            return self._call(jobs)
        self.worker.first_write_ns = None
        decoding = 0
        decode = wire.decode_response
        def measured_decode(payload):
            nonlocal decoding
            started = time.monotonic_ns()
            value = decode(payload)
            decoding += time.monotonic_ns() - started
            return value
        with patch.object(wire, "decode_response", measured_decode):
            started = time.monotonic_ns()
            values = self._call(jobs)
            total = time.monotonic_ns() - started
        encoding = self.worker.first_write_ns - started
        self.worker.codec_samples.append({"python_encode_and_validation_ns": encoding,
            "python_decode_ns": decoding, "exchange_ns": total - encoding - decoding,
            "definition": "Untimed diagnostic: entry-to-first-write includes adapter validation/framing; decode times BER1 typed decoding; exchange includes control parsing, transport AND native execution"})
        return values

    def close(self):
        if self.owner is not None and not self.owner.released:
            started = time.monotonic_ns()
            self.worker.release_prepared(self.owner, timeout=self.timeout)
            self.setup["release_service_ns"] = time.monotonic_ns() - started
            self.setup["after_release_retained_budget_bytes"] = self.worker.retained_bytes
            self.setup["after_release_memory"] = memory(self.worker.pid)
        self.worker.close()


class Native:
    def __init__(self, binary, mode, w, thread, shards, timeout, rounds, launcher=None):
        self.mode, self.count = mode, len(w.jobs)
        argv = [binary, *runtime_prefix(threads=thread, gpu="off"), mode, self.count, rounds]
        if mode in API_MODES:
            argv.append(shards)
        if launcher is not None:
            argv = [launcher, "--gate", *argv]
        started = time.monotonic_ns()
        self.worker = G.Worker(argv, timeout)
        self.setup = self.worker.ready(started)
        self.setup["command"] = list(map(str, argv))
        self.startup = self.setup["startup_ns"]
        if mode in API_MODES:
            q, config = prepared_definition(w)
            _, sample = self.worker.request(encode_request(q, b"", config), 0)
            self.setup.update(prepare_ns=sample["profile_ns"], clone_ns=sample["prepare_ns"],
                              effective_owners=sample["effective_owners"])
        self.setup.setdefault("prepare_ns", 0)
        self.setup.setdefault("clone_ns", 0)
        self.setup["memory_after_setup"] = (memory(self.worker.backend_pid) if rounds else
                                            {"status": "setup-only process; use launcher exit usage"})

    def call(self, jobs):
        payload = b"".join(encode_request(b"", t, c) if self.mode in API_MODES else encode_request(q, t, c)
                           for q, t, c in jobs)
        values, sample = self.worker.request(payload, len(jobs))
        if self.mode in ("prepare-batch", "prepare-clone", "profile-only"):
            self.setup["effective_owners"] = sample["effective_owners"]
        return values, sample

    def close(self):
        self.worker.close()


def build_references(directory, cxx, optimization, *, u32=False):
    directory.mkdir(parents=True)
    binaries, metadata = {}, {}
    source = G.ROOT / "vendor/edlib/edlib"
    variants = [("public", []), ("cached", ["-DCACHED_PROFILE=1"])]
    if u32:
        # The pinned source derives masks, shifts, padding and cell decoding
        # from sizeof(Word). Fail closed if its width definition changes.
        original = (source / "src/edlib.cpp").read_text()
        if original.count("typedef uint64_t Word;") != 1:
            raise RuntimeError("Review pinned Edlib word geometry before building U32")
        diagnostic = directory / "edlib_u32.cpp"
        diagnostic.write_text(original.replace("typedef uint64_t Word;", "typedef uint32_t Word;"))
        extra = [f'-DEDLIB_CONTROL_SOURCE="{diagnostic.resolve()}"']
        variants += [("public-u32-diagnostic", extra),
                     ("cached-u32-diagnostic", [*extra, "-DCACHED_PROFILE=1"])]
        metadata["u32_source"] = {"path": str(diagnostic), "sha256": G.digest(diagnostic.read_bytes()),
            "pinned_source_sha256": G.digest(original.encode()),
            "audit": "Word unsigned; WORD_SIZE=sizeof(Word)*8; WORD_1 typed; HIGH_BIT_MASK shifts by WORD_SIZE-1; Peq construction, block shifts and getBlockCellValues use WORD_SIZE; no other hard-coded 64/63/32 constants in pinned source"}
    for name, extra in variants:
        binary = directory / name
        argv = [*cxx, "-std=c++14", optimization, "-DNDEBUG", "-pthread", *extra,
                f'-DEDLIB_CONTROL_WORD_BITS={32 if "u32" in name else 64}',
                "-I", source / "include", G.ROOT / "benchmarks/edlib_control.cpp", "-o", binary]
        started = time.monotonic_ns()
        G.run_command(argv)
        binaries[name] = binary
        metadata[name] = {"command": list(map(str, argv)), "compile_ns": time.monotonic_ns() - started,
                          "binary_bytes": binary.stat().st_size, "binary_sha256": G.digest(binary.read_bytes())}
    binary = directory / "oracle"
    argv = [*cxx, "-std=c++14", optimization, "-DNDEBUG", "-I", source / "include",
            G.ROOT / "tests/edlib_oracle.cpp", source / "src/edlib.cpp", "-o", binary]
    G.run_command(argv)
    binaries["oracle"] = binary
    metadata["oracle"] = {"command": list(map(str, argv)), "binary_sha256": G.digest(binary.read_bytes())}
    return binaries, metadata


def reference_supported(w):
    try:
        _, c = prepared_definition(w)
        return c.mode == Mode.NW and c.task == Task.DISTANCE
    except ValueError:
        return False


def run(args, document, suite, cpus, bends, cc, cxx, output):
    modes = tuple(dict.fromkeys(args.mode or DEFAULT_MODES))
    document.update(references=[], inapplicable=[], coverage=[], builds={},
                    configured_timing_floor_ns=args.noise_floor_ns,
                    monotonic_clock_resolution_ns=time.get_clock_info("monotonic").resolution * 1e9,
                    empty_native_round_trigger_hex=encode_request(b"", b"", AlignConfig()).hex())
    document["phase_semantics"].update({
        "native_api_input": "One query setup frame, then BED1 target/config frames with an empty query; target extraction finishes before API timing. Empty batches use an explicit untimed trigger",
        "string-single": "lib.prepare then retained lib.align_prepared; String validation, search and complete result construction inside native_api_ns",
        "string-batch": "lib.prepare, PreparedPool.prepared cloning, then retained lib.align_prepared_pool_batch; planning/search/ordering/result construction inside native_api_ns",
        "string-serial-batch": "lib.prepare then retained lib.align_prepared_batch with one owner; target decoding/extraction outside native_api_ns",
        "service": "Unmodified AlignmentWorker call: Python encoding, native framing/decode, production dispatch/results, serialization, transport, Python decoding; validation outside call_ns",
        "compatible": "Explicit compatibility control disables optional op selection in adapter, uses production BED2 2/5",
        "prepare_pool_service_ns": "Complete prepare service call; includes owner cloning (not separately attributable through public protocol)",
        "prepared_group_budget_bytes": "Conservative cache charge while a fresh reuse group owns its query; retained_budget_bytes is sampled after release and must be zero",
        "prepare_ns": "Native lib.prepare only; clone_ns includes retained accounting and bounded pool construction",
        "prepare-batch": "Fresh lib.prepare + retained accounting/bounded pool cloning + one production String pool batch + forced pool disposal per call; decoding before timing and serialization after disposal. profile_ns/prepare_ns/work_ns/search_ns name those four stages respectively",
        "total_with_prepare_ns": "Preparation + cloning + sum of R batch/single call costs; excludes startup, release and validation",
        "fresh_prepared": "With --fresh-prepared, each service sample prepares a fresh production pool, executes R calls, then releases it. prepare_pool_service_ns includes framing/decode/native preparation/cloning; release_service_ns is separate. lifecycle_ns adds release. Native probes keep their stated boundary",
        "profile-only": "Isolated production P.build, with byte eligibility established by framed inputs and cached length before timing. profile_ns is construction; search_ns is forced profile disposal. No workspace or pool. Raw query/equalities remain held between cycles",
        "zero_result_latency": "Native zero-result requests complete at the metrics acknowledgement; nonzero requests complete at the last framed result, before decoding metrics",
        "alignment_calls": "Per-call elapsed_ns at the stated boundary; first_call_in_group_ns and repeated_calls_ns split each reuse group. --fresh-prepared gives each service group a new owner",
        "prepare-clone": "Additional attribution control: prepare-batch with an explicit Q.clone and disposal before pool construction; planning_ns/ordering_ns measure that clone/disposal. Exclude these extra operations from ordinary lifecycle comparisons",
        "call_ns": "Service: complete Python adapter call. Native probe: pre-encoded frame write to complete raw response, excluding Python encoding/decoding; native_api_ns is the separate forced API boundary",
        "public_edlib": "Public edlibAlign and edlibFreeAlignResult, raw query/equalities retained, persistent C++ workers; ordinary U64 implementation",
        "cached_edlib": "INTERNAL diagnostic: pinned U64 NW, retained compact alphabet/Peq, per-thread target mapping buffer; Edlib block scratch allocated per call; supports NW DISTANCE only, all bytes/equalities/thresholds/empty exceptions",
        "memory": "retained_budget_bytes is conservative admission accounting; rss_kib is current process RSS; peak_rss_kib is process VmHWM. Neither emitted C size nor budgets are live memory",
        "native_attribution": "Production native_api_ns includes search/planning/ordering/restoration/validation. Separate intrusive diagnostics use production pool primitives and Q.run_nw/R.reconstruct_known/A.path_validate; other modes retain combined execution. Legacy search_ns is never substituted",
        "process_usage": "Native launcher wait4: process_peak_rss_kib covers the backend child from a small native fork, excluding Python's inherited RSS. spawn_to_exit_peak_rss_kib covers the outer launcher including pre-exec Python inheritance. Live RSS/VmHWM are separate /proc observations"})
    document["phase_semantics"]["path_validation_ns"] = "Serial production NW diagnostic only: location validity plus R.valid_path, reported from slot 8; CIGAR and result construction use result_ns"
    document["phase_semantics"]["empty_batches"] = "Call overhead only: no per-target metric, throughput, or Bend/Edlib alignment ratio"
    driver_directory = output / "driver"
    for relative in document["provenance"]["driver_sha256"]:
        target = driver_directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(G.ROOT / relative, target)
    document["workloads"] = [{"name": w.name, "seed": w.seed, "reuse_count": w.reuse_count,
        "batch_size": len(w.jobs), "batches": [[G.digest(encode_request(*j)) for j in batch] for batch in w.batches or (w.jobs,)],
        "prepared_query_sha256": G.digest(prepared_definition(w)[0]) if applicable("string-batch", w) is None else None,
        "native_api_batch_sha256": [G.digest(b"".join(encode_request(b"", t, c) for _, t, c in batch)) for batch in w.batches or (w.jobs,)],
        "setup_frame_hex": encode_request(prepared_definition(w)[0], b"", prepared_definition(w)[1]).hex() if applicable("string-batch", w) is None else None}
        for w in suite]
    document["inputs"] = {G.digest(encode_request(*j)): encode_request(*j).hex()
        for w in suite for batch in w.batches or (w.jobs,) for j in batch}
    document["suite_sha256"] = G.digest(json.dumps(document["workloads"], sort_keys=True).encode())
    # Keep all binaries/emitted C/source snapshots beside raw results for audit.
    scratch = output / "builds"
    scratch.mkdir(parents=True, exist_ok=True)
    launcher = scratch / "launch"
    launcher_command = [*cc, "-std=c2x", "-O3", G.ROOT / "benchmarks/launch.c", "-o", launcher]
    G.run_command(launcher_command)
    document["native_launcher"] = {"command": list(map(str, launcher_command)),
        "source_sha256": G.digest((G.ROOT / "benchmarks/launch.c").read_bytes()), "binary_sha256": G.digest(launcher.read_bytes())}
    flags = {v: shlex.split(getattr(args, v + "_cflags") or args.cflags) for v in ("baseline", "candidate")}
    optimizations = {next((f for f in reversed(fs) if f.startswith("-O")), "-O0") for fs in flags.values()}
    if len(optimizations) != 1:
        raise ValueError("Production Bend/Edlib references require matched optimization levels")
    reference_options = {"u32": True} if args.edlib_u32 else {}
    refs, document["reference_builds"] = build_references(scratch / "edlib", cxx, optimizations.pop(), **reference_options)
    kinds = set("profile" if m == "profile-only" else "preparation" if m in ("prepare-batch", "prepare-clone") else "api" if m in API_MODES else "core" if m in CORE_MODES else "worker" for m in modes)
    if "worker" in kinds:
        kinds.add("api")  # Untimed owner-count observation using identical public pool preparation.
    if args.allocations:
        kinds.add("diagnostic")
    binaries = {}
    for variant, root in (("baseline", args.baseline), ("candidate", args.candidate)):
        for kind in sorted(kinds):
            print(f"Building {variant} production {kind}...", flush=True)
            entry = {"profile": "benchmarks/profile_preparation.bend", "preparation": "benchmarks/production_preparation.bend", "api": "benchmarks/production_api.bend", "core": "benchmarks/gate_probe.bend", "worker": "worker.bend", "diagnostic": "benchmarks/production_diagnostics.bend"}[kind]
            binary, meta = G.build(root.resolve(), scratch / variant / kind, bends[variant], cc, flags[variant],
                entry_name=entry, allocations=kind == "diagnostic",
                compiler_identity=document["provenance"]["bend_compilers"][variant])
            binaries[variant, kind] = binary
            document["builds"][variant + "/" + kind] = meta
    oracle = AlignmentWorker([refs["oracle"], "--worker"])
    try:
        for w in suite:
            batches = w.batches or (w.jobs,)
            expected = [[oracle.align(*j, timeout=args.timeout) for j in jobs] for jobs in batches]
            for jobs, values in zip(batches, expected):
                G.validate(values, values, replace(w, jobs=jobs))
            for mode in modes:
                reason = applicable(mode, w)
                if reason:
                    document["inapplicable"].append({"workload": w.name, "mode": mode, "reason": reason})
                    continue
                kind = "profile" if mode == "profile-only" else "preparation" if mode in ("prepare-batch", "prepare-clone") else "api" if mode in API_MODES else "core" if mode in CORE_MODES else "worker"
                for thread in args.threads:
                    shards = args.shards or thread
                    rounds = (args.warmups + args.repeats) * w.reuse_count
                    with G.affinity(cpus[:thread]), ExitStack() as stack:
                        sessions, records = {}, {}
                        for variant in G.ordered_variants(0):
                            binary = binaries[variant, kind]
                            evidence = {"requested_route": mode, "actual_route": mode,
                                "observation": "closed native entry invokes shipped API; source hashes retained"}
                            if kind == "worker":
                                diagnostic = Service(binary, mode, w, thread, shards, args.timeout, observed=True)
                                try:
                                    for jobs, values in zip(batches, expected):
                                        actual = diagnostic.call(jobs)
                                        G.validate(actual, values, replace(w, jobs=jobs))
                                    evidence = route_evidence(mode, diagnostic.worker.operations, diagnostic.worker.controls)
                                    evidence["codec_diagnostics"] = diagnostic.worker.codec_samples
                                finally:
                                    diagnostic.close()
                                session = Service(binary, mode, w, thread, shards, args.timeout, fresh=args.fresh_prepared)
                            else:
                                session = Native(binary, mode, w, thread, shards, args.timeout, rounds, launcher=launcher)
                            if kind == "worker" and not mode.startswith("ordinary"):
                                owner_probe = Native(binaries[variant, "api"], "string-batch", w, thread, shards, args.timeout, 0, launcher=launcher)
                                try:
                                    session.setup["effective_owners"] = owner_probe.setup["effective_owners"]
                                    session.setup["diagnostic_prepare_ns"] = owner_probe.setup["prepare_ns"]
                                    session.setup["diagnostic_clone_ns"] = owner_probe.setup["clone_ns"]
                                    owner_probe.worker.finish()
                                finally:
                                    owner_probe.close()
                            stack.callback(session.close)
                            sessions[variant] = session
                            records[variant] = {"workload": w.name, "variant": variant, "mode": mode,
                                "lifetime": "persistent", "backend": "cpu", "threads": thread,
                                "runtime_threads": thread, "runtime_thread_evidence": "explicit RTS argv, BENDRTS cleared; OS thread count and affinity sampled separately",
                                "boundary": "native-probe-framed-round-trip" if kind in ("profile", "preparation", "api", "core") else "python-service",
                                "requested_shards": shards, "effective_owners": session.setup.get("effective_owners"),
                                "owner_observation": "separate identical public prepare_with_max pool observation; active execution leaves are not exposed" if kind == "worker" else "native pool metadata per cycle" if kind == "preparation" else "one isolated profile" if kind == "profile" else "native pool metadata" if kind == "api" else "not applicable",
                                "batch_size": len(w.jobs), "batch_call_count": w.reuse_count,
                                "total_target_count": len(w.jobs) * w.reuse_count, "affinity_cpus": cpus[:thread],
                                "setup": session.setup, "execution": evidence, "samples": []}
                        reference_sessions = {}
                        if reference_supported(w) and mode not in ("phases", "prepared"):
                            for name in (n for n in refs if n != "oracle" and
                                         (not mode.startswith("ordinary") or n.startswith("public"))):
                                reference_mode = mode if mode.startswith("ordinary") else "compatible-worker-single" if mode.endswith("single") else "compatible-worker-batch"
                                session = Service(refs[name], reference_mode, w, thread, shards, args.timeout, reference=True)
                                stack.callback(session.close)
                                # Verify cached control against public oracle before accepting any timing.
                                for index, (jobs, values) in enumerate(zip(batches, expected)):
                                    started = time.monotonic_ns()
                                    actual = session.call(jobs)
                                    if index == 0:
                                        session.setup["first_alignment_ns"] = time.monotonic_ns() - started
                                    G.validate(actual, values, replace(w, jobs=jobs))
                                reference_sessions[name] = session
                        reference_records = {name: {**records["baseline"], "variant": "edlib-" + name,
                            "backend": "edlib-" + name, "setup": session.setup, "boundary": "python-service",
                            "requested_shards": None, "effective_owners": None if mode.startswith("ordinary") else 1,
                            "runtime_thread_evidence": "persistent C++ worker constructor argv; OS thread count and affinity sampled separately",
                            "owner_observation": "no retained query across ordinary requests" if mode.startswith("ordinary") else "one immutable retained C++ query/profile shared by persistent threads; cached mapping buffers are thread-local",
                            "first_alignment_ns": session.setup["first_alignment_ns"],
                            "execution": {"actual_route": ("public edlibAlign" if name.startswith("public") else "internal cached NW"),
                                          "word_bits": 32 if "u32" in name else 64,
                                          "diagnostic": "u32" in name}, "samples": []}
                            for name, session in reference_sessions.items()}
                        for repetition in range(args.warmups + args.repeats):
                            order = list(G.ordered_variants(repetition))
                            # Rotate C++ controls around the paired samples, avoiding a fixed thermal order.
                            order = (list(reference_sessions) + order) if repetition % 2 else (order + list(reference_sessions))
                            for position, variant in enumerate(order):
                                session = sessions.get(variant) or reference_sessions[variant]
                                total = native = serialization = validation = 0
                                stages = dict.fromkeys(G.PHASES, 0)
                                group_prepare = session.begin_group() if isinstance(session, Service) else None
                                batch_ids, output_hashes, call_times = [], [], []
                                for call in range(w.reuse_count):
                                    index = (repetition * w.reuse_count + call) % len(batches)
                                    jobs = batches[index]
                                    started = time.monotonic_ns()
                                    if isinstance(session, Native):
                                        values, sample = session.call(jobs)
                                        elapsed = sample["request_latency_ns"]
                                        native += sample["total_cost_ns"]
                                        serialization += sample["serialization_ns"]
                                        for phase in stages:
                                            stages[phase] += sample[phase]
                                    else:
                                        values = session.call(jobs)
                                        elapsed = time.monotonic_ns() - started
                                    if repetition == 0 and call == 0:
                                        (records.get(variant) or reference_records[variant]).setdefault("first_alignment_ns", elapsed)
                                    total += elapsed
                                    call_times.append(elapsed)
                                    started = time.monotonic_ns()
                                    G.validate(values, expected[index], replace(w, jobs=jobs))
                                    validation += time.monotonic_ns() - started
                                    batch_ids.append(index)
                                    output_hashes.append(G.digest(json.dumps([v.to_edlib() for v in values], sort_keys=True).encode()))
                                record = records.get(variant) or reference_records[variant]
                                setup = session.setup
                                prepare = group_prepare if group_prepare is not None else setup.get("prepare_ns", 0) + setup.get("clone_ns", 0)
                                release = session.end_group() if isinstance(session, Service) else 0
                                sample = {"repetition": repetition - args.warmups, "order": position,
                                    "batch_indices": batch_ids, "output_sha256": output_hashes,
                                    "call_ns": total, "validation_ns": validation,
                                    "alignment_calls": [{"index": i, "elapsed_ns": n} for i, n in enumerate(call_times)],
                                    "first_call_in_group_ns": call_times[0],
                                    "repeated_calls_ns": sum(call_times[1:]),
                                    "total_with_prepare_ns": prepare + total}
                                if isinstance(session, Service) and session.fresh:
                                    sample.update(prepare_pool_service_ns=prepare, release_service_ns=release,
                                                  lifecycle_ns=prepare + total + release,
                                                  prepared_group_budget_bytes=session.group_bytes)
                                if isinstance(session, Native):
                                    sample["native_api_ns"] = native
                                    sample["native_serialization_ns"] = serialization
                                    sample.update(stages)
                                else:
                                    sample.update(memory(session.worker.pid))
                                    sample["retained_budget_bytes"] = session.worker.retained_bytes
                                    if session.worker.retained_bytes != session.setup["retained_budget_bytes"]:
                                        raise RuntimeError("Prepared cache accounting changed during retained calls")
                                if w.jobs:
                                    sample["amortized_per_target_ns"] = (prepare + total) / (len(w.jobs) * w.reuse_count)
                                    sample["targets_per_second"] = len(w.jobs) * w.reuse_count * 1e9 / total
                                if repetition == 0:
                                    record["first_group_ns"] = total
                                if repetition >= args.warmups:
                                    record["samples"].append(sample)
                        for variant, session in sessions.items():
                            if isinstance(session, Native):
                                records[variant]["effective_owners"] = session.setup.get("effective_owners")
                                session.worker.finish()
                                records[variant]["process_usage"] = session.worker.exit_usage
                        for record in (*records.values(), *reference_records.values()):
                            record["summary"] = summarize(record["samples"])
                        document["records"].extend(records.values())
                        document["references"].extend(reference_records.values())
                        document["coverage"].append({"workload": w.name, "mode": mode, "threads": thread, "validated": True})
                print(f"Validated and measured {w.name} {mode}", flush=True)
            if args.allocations and applicable("string-batch", w) is None:
                for thread in args.threads:
                    for variant in G.ordered_variants(0):
                        for diagnostic_mode in ("string-diagnostic", "search-diagnostic"):
                            with G.affinity(cpus[:thread]):
                                diagnostic = Native(binaries[variant, "diagnostic"], diagnostic_mode, w,
                                    thread, args.shards or thread, args.timeout, len(batches), launcher=launcher)
                                try:
                                    for jobs, values in zip(batches, expected):
                                        actual, metrics = diagnostic.call(jobs)
                                        G.validate(actual, values, replace(w, jobs=jobs))
                                        if "heap_alloc_calls" not in metrics:
                                            raise RuntimeError("Missing production allocation diagnostic")
                                        document["allocations"].append({"variant": variant, "workload": w.name,
                                            "threads": thread, "boundary": "intrusive production String pool stages" if diagnostic_mode == "string-diagnostic" else "serial production Q.run_nw search/result diagnostic",
                                            "setup": diagnostic.setup, **metrics,
                                            "path_validation_ns": metrics["locations_ns"] if diagnostic_mode == "search-diagnostic" else 0})
                                    diagnostic.worker.finish()
                                finally:
                                    diagnostic.close()
        required = {(w.name, m, t) for w in suite for m in modes for t in args.threads if applicable(m, w) is None}
        actual = {(r["workload"], r["mode"], r["threads"]) for r in document["coverage"]}
        if not required or actual != required:
            raise RuntimeError("Incomplete production path coverage")
        document["comparisons"] = G.paired_gate(document["records"], args.max_regression, args.gate_metric or ["call_ns"], args.noise_floor_ns)
        if not document["comparisons"]:
            raise RuntimeError("No applicable production performance metrics")
        document["status"] = "passed" if all(c["passed"] for c in document["comparisons"]) else "performance_regression"
        document["edlib_comparisons"] = []
        for b in document["records"]:
            if b["boundary"] != "python-service" or b["batch_size"] == 0:
                continue
            for e in document["references"]:
                if any(b[k] != e[k] for k in ("workload", "mode", "threads")):
                    continue
                if [x["batch_indices"] for x in b["samples"]] != [x["batch_indices"] for x in e["samples"]]:
                    raise RuntimeError("Unpaired Bend/Edlib inputs")
                ratios = [x["call_ns"] / y["call_ns"] for x, y in zip(b["samples"], e["samples"])]
                import statistics
                document["edlib_comparisons"].append({"workload": b["workload"], "mode": b["mode"],
                    "threads": b["threads"], "variant": b["variant"], "reference": e["variant"],
                    "batch_size": b["batch_size"], "total_target_count": b["total_target_count"],
                    "boundary": "python-service", "bend_median_ns": b["summary"]["call_ns"]["median"],
                    "edlib_median_ns": e["summary"]["call_ns"]["median"],
                    "bend_over_edlib": statistics.median(ratios), "paired_ratios": ratios,
                    **G.observation([x["call_ns"] - y["call_ns"] for x, y in zip(b["samples"], e["samples"])], args.noise_floor_ns)})
        print(f"{document['status']}: {len(document['coverage'])} validated production cells; results: {output}", flush=True)
        document["acceptance_scope"] = "Selected measured matrix only; semantic suites and unmeasured attribution require separate acceptance"
    finally:
        oracle.close()
