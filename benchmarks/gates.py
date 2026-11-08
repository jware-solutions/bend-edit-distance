"""Paired source comparisons shared by the CPU and strict CUDA harnesses."""

from __future__ import annotations

import argparse
from contextlib import contextmanager, ExitStack
import csv
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import selectors
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time

from alignment import AlignConfig, CigarFormat, EqualityPair, Mode, Operation, Status, Task, MaxDistance, Unlimited
from bend_runtime import reproducible_env, runtime_prefix
from transport import LENGTH, MAX_FRAME_LENGTH, RESPONSE, decode_response, encode_request, sequence_bytes

ROOT = Path(__file__).resolve().parents[1]
PHASES = ("planning_ns", "work_ns", "ordering_ns", "profile_ns", "search_ns",
          "reconstruction_ns", "serialization_ns", "prepare_ns", "locations_ns", "result_ns")
READY = b"BEND_GATE_READY "
METRICS = b"BEND_GATE_METRICS "
ALLOC_ANCHOR = "INLINE u64 heap_alloc(Env e, u32 cls) {"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def physical_cpus(allowed):
    """One allowed logical CPU per physical core; never select SMT siblings."""
    seen, selected = set(), []
    for cpu in sorted(allowed):
        topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        key = ((topology / "physical_package_id").read_text().strip(),
               (topology / "core_id").read_text().strip())
        if key not in seen:
            seen.add(key)
            selected.append(cpu)
    return selected


@dataclass(frozen=True)
class Workload:
    name: str
    jobs: tuple
    distances: tuple | None = None
    reuse: bool = False
    batches: tuple = ()
    reuse_count: int = 1
    prepared_query: tuple | None = None
    seed: int | None = None

    @property
    def payload(self):
        return b"".join(encode_request(*job) for job in self.jobs)


def workloads(corpus, sizes, reuse_counts):
    """Keep every corpus pair; additions are deterministic and independently named."""
    output = []
    cases = corpus["cases"]
    for case in cases:
        for count in sizes:
            output.append(Workload(f"{case['name']}/{count}",
                ((case["query"], case["target"], AlignConfig()),) * count,
                (case["distance"],) * count))
    pairs = tuple(EqualityPair(i, i + 32) for i in range(65, 89))
    configured = tuple((q, t, AlignConfig(mode, task, threshold,
        (EqualityPair("N", "A"), EqualityPair("N", "C")), format))
        for mode in Mode for task in Task for format in CigarFormat
        for threshold in (Unlimited(), MaxDistance(0), MaxDistance(2))
        for q, t in ((b"AN", b"TACNAC"), (b"", b"AC"), (b"AC", b"")))
    output.append(Workload("configured", configured))
    for count in sizes:
        selected = tuple(cases[(i * 7) % len(cases)] for i in range(count))
        output.append(Workload(f"mixed/{count}", tuple(
            (c["query"], c["target"], AlignConfig()) for c in selected),
            tuple(c["distance"] for c in selected)))
        skewed = ((b"ACG", b"ACGT" * 1024, AlignConfig()),
                  (b"ACGT" * 1024, b"ACG", AlignConfig()),
                  (b"ACGT" * 16 + b"A", b"G", AlignConfig()),
                  (b"", b"A" * 513, AlignConfig()))
        output.append(Workload(f"skewed/{count}", tuple(skewed[i % 4] for i in range(count))))
        output.append(Workload(f"equalities/{count}", tuple(
            ((b"ACGTN" * 13, b"acgtn" * 13 + bytes([65 + i % 24]), AlignConfig(equalities=pairs))
             if i % 2 == 0 else (b"\0\xff\x7f" * 21, b"\xff\0\x7f" * 21,
                AlignConfig(equalities=(*pairs, EqualityPair(0, 255), EqualityPair(255, 127)))))
            for i in range(count))))
    query = b"ACGT" * 32 + b"A"
    targets = (query + b"C", b"T" + query, query[:-1] + b"G", query + b"ACGT" * 16)
    output.append(Workload("reconstruction", tuple(
        (query, t, AlignConfig(task=Task.PATH, cigar_format=f))
        for f in CigarFormat for t in targets)))
    for count in reuse_counts:
        output.append(Workload(f"repeated/{count}", tuple(
            (query, targets[i % len(targets)], AlignConfig()) for i in range(count)), reuse=True))
    return output


def validate_prepared(jobs):
    if not jobs:
        raise ValueError("Prepared workloads must be nonempty")
    first_q, _, first_config = jobs[0]
    for q, t, config in jobs:
        if (not q or not t or sequence_bytes(q) != sequence_bytes(first_q)
                or config != first_config or config.mode != Mode.NW or len(q) > len(t)):
            raise ValueError("Prepared workloads require one nonempty NW query/config and targets at least as long")


def validate_path(job, result):
    """Check every operation and CIGAR run independently of optimal-path ties."""
    q, t, config = job
    q, t = sequence_bytes(q), sequence_bytes(t)
    if result.alignment is None:
        if (config.task == Task.PATH and result.edit_distance >= 0 and q and t
                or result.cigar is not None):
            raise RuntimeError("Missing requested alignment/CIGAR")
        return
    if config.task != Task.PATH or not result.start_locations or not result.end_locations:
        raise RuntimeError("Unexpected path or missing path locations")
    start, end = result.start_locations[0].to_edlib(), result.end_locations[0].to_edlib()
    if not 0 <= start <= end + 1 <= len(t):
        raise RuntimeError("Invalid path interval")
    segment = t[start:end + 1]
    equalities = {tuple(p.to_bytes()) for p in config.equalities}
    equalities |= {(b, a) for a, b in equalities}
    qi = ti = cost = 0
    runs = []
    for op in result.alignment:
        if op in (Operation.MATCH, Operation.MISMATCH):
            if qi >= len(q) or ti >= len(segment):
                raise RuntimeError("Path exceeds inputs")
            equal = q[qi] == segment[ti] or (q[qi], segment[ti]) in equalities
            if equal != (op == Operation.MATCH):
                raise RuntimeError("Path equality mismatch")
            qi += 1
            ti += 1
            symbol = "M" if config.cigar_format == CigarFormat.STANDARD else "=" if equal else "X"
        elif op == Operation.INSERT:
            qi += 1
            symbol = "I"
        elif op == Operation.DELETE:
            ti += 1
            symbol = "D"
        else:
            raise RuntimeError("Unknown path operation")
        cost += op != Operation.MATCH
        if runs and runs[-1][1] == symbol:
            runs[-1] = (runs[-1][0] + 1, symbol)
        else:
            runs.append((1, symbol))
    cigar = "".join(str(n) + s for n, s in runs)
    if (qi, ti, cost, cigar) != (len(q), len(segment), result.require_distance(), result.cigar):
        raise RuntimeError("Path/CIGAR consumption or cost mismatch")


def validate(values, expected, workload, *, exact=False):
    if len(values) != len(workload.jobs) or len(expected) != len(values):
        raise RuntimeError(f"Result count mismatch: {workload.name}")
    for i, (job, actual, oracle) in enumerate(zip(workload.jobs, values, expected)):
        # Edlib can choose another optimal path on large matrices. Coordinates,
        # status and distance must match exactly; validate both complete paths.
        if (actual.status != Status.OK or
            (actual.status, actual.distance, actual.end_locations, actual.start_locations) !=
                (oracle.status, oracle.distance, oracle.end_locations, oracle.start_locations)):
            raise RuntimeError(f"Ordered result mismatch: {workload.name}, job {i}")
        if ((actual.alignment is None, actual.cigar is None) !=
                (oracle.alignment is None, oracle.cigar is None)):
            raise RuntimeError(f"Optional field presence mismatch: {workload.name}, job {i}")
        validate_path(job, actual)
        validate_path(job, oracle)
        if max(len(sequence_bytes(job[0])), len(sequence_bytes(job[1]))) <= 64:
            if actual.edit_distance != dp_distance(*job):
                raise RuntimeError(f"Independent DP distance mismatch: {workload.name}, job {i}")
        if exact and actual != oracle:
            raise RuntimeError(f"Complete baseline/candidate result mismatch: {workload.name}, job {i}")
        if workload.distances is not None and actual.edit_distance != workload.distances[i]:
            raise RuntimeError(f"Corpus distance mismatch: {workload.name}, job {i}")


def dp_distance(query, target, config):
    """Small independent unit-cost oracle, including Edlib's empty exceptions."""
    q, t = sequence_bytes(query), sequence_bytes(target)
    if not q or not t:
        return max(len(q), len(t)) if config.mode == Mode.NW else len(q)
    pairs = {tuple(p.to_bytes()) for p in config.equalities}
    pairs |= {(b, a) for a, b in pairs}
    previous = list(range(len(t) + 1)) if config.mode != Mode.HW else [0] * (len(t) + 1)
    for i, a in enumerate(q, 1):
        row = [i]
        for j, b in enumerate(t, 1):
            row.append(min(previous[j] + 1, row[-1] + 1,
                           previous[j - 1] + (a != b and (a, b) not in pairs)))
        previous = row
    optimum = previous[-1] if config.mode == Mode.NW else min(previous)
    limit = config.threshold.to_edlib()
    return optimum if limit < 0 or optimum <= limit else -1


@contextmanager
def affinity(cpus):
    previous = os.sched_getaffinity(0)
    try:
        os.sched_setaffinity(0, cpus)
        yield
    finally:
        os.sched_setaffinity(0, previous)


class Worker:
    """Deadline-bounded byte exchange; encoding and validation are outside timing."""

    def __init__(self, argv, timeout):
        self.timeout = timeout
        self.process = subprocess.Popen(list(map(str, argv)), cwd=ROOT, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, env=reproducible_env(),
            start_new_session=True)
        self.closed = False
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            os.set_blocking(pipe.fileno(), False)
        self.deadline = time.monotonic() + timeout

    def _wait(self, pipe, event):
        with selectors.DefaultSelector() as selector:
            selector.register(pipe, event)
            remaining = self.deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise RuntimeError("Benchmark worker timed out")

    def read(self, pipe, size):
        data = bytearray()
        while len(data) < size:
            self._wait(pipe, selectors.EVENT_READ)
            try:
                chunk = os.read(pipe.fileno(), size - len(data))
            except BlockingIOError:
                continue
            if not chunk:
                raise RuntimeError(f"Benchmark worker closed a stream (exit={self.process.poll()})")
            data.extend(chunk)
        return bytes(data)

    def line(self):
        data = bytearray()
        while len(data) < 65536:
            data.extend(self.read(self.process.stderr, 1))
            if data.endswith(b"\n"):
                return bytes(data)
        raise RuntimeError("Oversized benchmark diagnostic")

    def ready(self, started):
        line = self.line()
        self.backend_pid = self.process.pid
        native_spawned = None
        if line.startswith(b"BEND_GATE_CHILD "):
            pid, native_spawned = map(int, line.split()[1:])
            self.backend_pid = pid
            line = self.line()
        if not line.startswith(READY):
            raise RuntimeError(f"Missing benchmark startup handshake: {line!r}")
        ready = int(line[len(READY):])
        observed = time.monotonic_ns()
        if not started <= ready <= observed:
            raise RuntimeError("Benchmark clocks do not share an epoch")
        result = {"startup_ns": ready - started, "startup_handshake_ns": observed - started}
        if native_spawned is not None:
            if not started <= native_spawned <= ready:
                raise RuntimeError("Invalid native launcher clock")
            result.update(launcher_ns=native_spawned - started, native_startup_ns=ready - native_spawned)
        return result

    def request(self, payload, count, *, metrics=True):
        self.deadline = time.monotonic() + self.timeout
        if metrics and count == 0 and not payload:
            payload = encode_request(b"", b"", AlignConfig())
        started = time.monotonic_ns()
        view = memoryview(payload)
        while view:
            self._wait(self.process.stdin, selectors.EVENT_WRITE)
            try:
                size = os.write(self.process.stdin.fileno(), view)
            except BlockingIOError:
                continue
            view = view[size:]
        values = []
        raw = bytearray()
        for _ in range(count):
            header = self.read(self.process.stdout, LENGTH.size)
            size = LENGTH.unpack(header)[0]
            if not RESPONSE.size <= size <= MAX_FRAME_LENGTH:
                raise RuntimeError("Invalid result frame size")
            frame = self.read(self.process.stdout, size)
            raw.extend(header + frame)
            values.append(frame)
        # Complete framed output is the latency boundary; decode afterwards.
        latency = time.monotonic_ns() - started
        sample = {"request_latency_ns": latency, "output_sha256": digest(raw)}
        if metrics:
            line = self.line()
            if not line.startswith(METRICS):
                raise RuntimeError(f"Missing phase metrics: {line!r}")
            data = json.loads(line[len(METRICS):])
            phases = data.pop("phases", None)
            if (data.pop("schema", None) != 1 or not isinstance(phases, list) or len(phases) != len(PHASES)
                    or any(type(n) is not int or n < 0 for n in phases)
                    or any(type(n) is not int or n < 0 for n in data.values())):
                raise RuntimeError("Invalid phase metrics")
            sample.update(zip(PHASES, phases))
            sample.update(data)
            sample["total_cost_ns"] = sum(phases) - sample["serialization_ns"]
            if count:
                sample["amortized_total_ns"] = sample["total_cost_ns"] / count
                sample["search_per_query_ns"] = sample["search_ns"] / count
        return [decode_response(frame) for frame in values], sample

    def finish(self):
        self.process.stdin.close()
        try:
            # Wait without reaping first, so wait4 reports this child's peak
            # RSS rather than Python's or an earlier child's cumulative peak.
            descriptor = None
            try:
                descriptor = os.pidfd_open(self.process.pid)
            except (AttributeError, OSError):
                pass
            if descriptor is None:
                code = self.process.wait(timeout=self.timeout)
                self.exit_usage = {"status": "wait4 unavailable"}
            else:
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(descriptor, selectors.EVENT_READ)
                        if not selector.select(self.timeout):
                            raise RuntimeError("Benchmark worker exit timed out")
                    _, status, usage = os.wait4(self.process.pid, 0)
                    code = os.waitstatus_to_exitcode(status)
                    self.process.returncode = code
                    self.exit_usage = {"spawn_to_exit_peak_rss_kib": usage.ru_maxrss,
                        "spawn_to_exit_cpu_ns": int((usage.ru_utime + usage.ru_stime) * 1e9)}
                finally:
                    os.close(descriptor)
            # Exact count, no trailing result or diagnostic can go unchecked.
            extra = self.process.stdout.read() or b""
            error = self.process.stderr.read() or b""
            if error.startswith(b"BEND_GATE_USAGE ") and error.count(b"\n") == 1:
                usage = json.loads(error[len(b"BEND_GATE_USAGE "):])
                if set(usage) != {"process_peak_rss_kib", "process_cpu_ns"} or any(type(v) is not int or v < 0 for v in usage.values()):
                    raise RuntimeError("Invalid native launcher usage")
                self.exit_usage.update(usage)
                error = b""
            if code or extra or error:
                raise RuntimeError(f"Worker exit={code}, trailing stdout={extra[:200]!r}, stderr={error[:1000]!r}")
        finally:
            self.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.poll() is None:
            os.killpg(self.process.pid, 9)
        self.process.wait()
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            pipe.close()


def run_command(argv):
    result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, text=True,
                            timeout=300, env=reproducible_env())
    if result.returncode:
        raise RuntimeError(f"Build failed: {list(map(str, argv))!r}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def compiler_command(command):
    """Keep an explicitly selected executable path (including spaces) intact."""
    return [command] if Path(command).is_file() else shlex.split(command)


def select_compilers(args):
    """A release override requires both an executable and an expected version.

    Merely changing PATH or --bend never bypasses either source tree's pin.
    """
    selections = {}
    for variant in ("baseline", "candidate"):
        root = getattr(args, variant).resolve()
        pin = (root / ".bend-version").read_text().strip()
        command = getattr(args, variant + "_bend")
        expected = getattr(args, variant + "_bend_version")
        if expected is not None and command is None:
            raise ValueError(f"--{variant}-bend-version requires --{variant}-bend")
        expected = expected if expected is not None else pin
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", expected):
            raise ValueError(f"Invalid expected {variant} Bend release: {expected!r}")
        path = Path(shutil.which(command or args.bend) or command or args.bend).resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"{variant} Bend is not executable: {path}")
        version = run_command([path, "version"])
        if version != "bend " + expected:
            raise RuntimeError(f"{variant} compiler mismatch: expected bend {expected}, found {version}; "
                               "an intentional release comparison needs an explicit executable and --" +
                               variant + "-bend-version")
        bundled = path.parent.parent / "bend2"
        selections[variant] = {"path": str(path), "version": version, "expected_release": expected,
            "source_pin": pin, "release_override": expected != pin,
            "sha256": digest(path.read_bytes()),
            "bundled_sources_sha256": {str(p.relative_to(bundled)): digest(p.read_bytes())
                for p in sorted(bundled.rglob("*")) if p.is_file()} if bundled.is_dir() else {}}
    return selections


def snapshot(root, destination):
    destination.mkdir(parents=True)
    paths = [*root.glob("*.bend"), *root.glob("src/**/*.bend"),
             *root.glob("src/**/*.c"), *root.glob("src/**/*.js"), root / ".bend-version"]
    hashes = {}
    for path in sorted(paths):
        relative = path.relative_to(root)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        hashes[str(relative)] = digest(target.read_bytes())
    for name in ("gate_probe.bend", "gate_input.bend", "gate_metrics.bend", "gate_metrics.c", "production_api.bend", "production_diagnostics.bend", "compatible_worker.bend"):
        target = destination / "benchmarks" / name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / "benchmarks" / name, target)
        hashes["benchmarks/" + name] = digest(target.read_bytes())
    return hashes


def allocation_source(source):
    if source.count(ALLOC_ANCHOR) != 1:
        raise RuntimeError("Pinned allocator changed; review allocation instrumentation")
    return source.replace(ALLOC_ANCHOR,
        "static _Atomic uint64_t gate_allocations;\n" + ALLOC_ANCHOR +
        "\n  atomic_fetch_add_explicit(&gate_allocations, 1, memory_order_relaxed);")


def build(root, directory, bend, cc, flags, *, device=False, allocations=False,
          entry_name="benchmarks/gate_probe.bend", compiler_identity=None):
    from benchmarks.gpu_runner import instrument, prerequisites, require_gpu_build
    bend = Path(shutil.which(str(bend)) or bend).resolve()
    identity = {"path": str(bend), "version": run_command([bend, "version"]),
                "sha256": digest(bend.read_bytes())}
    if compiler_identity is not None and any(identity[k] != compiler_identity[k] for k in identity):
        raise RuntimeError("Selected Bend compiler changed before build")
    hashes = snapshot(root, directory / "source")
    entry = directory / "source" / entry_name
    if device:
        text = entry.read_text()
        if text.count("  B.execute(plan)") != 1:
            raise RuntimeError("Review GPU benchmark entry substitution")
        entry.write_text(text.replace("  B.execute(plan)", "  B.execute!(plan)"))
    hashes[entry_name] = digest(entry.read_bytes())
    source, binary = directory / "probe.c", directory / "probe"
    commands = [[bend, entry, "-o", source]]
    started = time.monotonic_ns()
    run_command(commands[0])
    emission_ns = time.monotonic_ns() - started
    emitted = source.read_text()
    if device:
        emitted = instrument(emitted)
    if allocations:
        if device:
            raise ValueError("Allocation diagnostics require the CPU-only binary")
        emitted = allocation_source(emitted)
    source.write_text(emitted)
    argv = [*cc, *flags, source, "-lm", "-o", binary]
    if device:
        cuda, _, problems = prerequisites(cc)
        if problems:
            raise RuntimeError("; ".join(problems))
        lib = cuda / ("lib64" if (cuda / "lib64").is_dir() else "lib")
        argv += ["-DGATE_DEVICE_EVIDENCE=1", "-DBEND_CUDA=1", "-I", cuda / "include",
                 "-L", lib, f"-Wl,-rpath,{lib}", "-lcuda", "-lnvrtc"]
    if allocations:
        argv.append("-DGATE_ALLOCATIONS=1")
    commands.append(argv)
    started = time.monotonic_ns()
    run_command(argv)
    compile_ns = time.monotonic_ns() - started
    if digest(bend.read_bytes()) != identity["sha256"]:
        raise RuntimeError("Selected Bend compiler changed during build")
    metadata = {"bend": identity,
        "sources_sha256": hashes, "emitted_c_sha256": digest(source.read_bytes()),
        "binary_sha256": digest(binary.read_bytes()), "allocations": allocations,
        "emission_ns": emission_ns, "compile_ns": compile_ns,
        "emitted_c_bytes": source.stat().st_size, "binary_bytes": binary.stat().st_size,
        "commands": [list(map(str, cmd)) for cmd in commands]}
    # Clang's dry run expands wrappers and implicit target/link options without
    # adding the wrapper's policy flags a second time to the timed executable.
    trace = subprocess.run(list(map(str, [*argv, "-###"])), cwd=ROOT,
        capture_output=True, text=True, timeout=30, env=reproducible_env())
    if trace.returncode:
        raise RuntimeError(f"Cannot record effective host compiler options: {trace.stderr}")
    metadata["host_driver_trace"] = trace.stdout + trace.stderr
    if device:
        metadata["device_program"] = require_gpu_build(binary)
    return binary, metadata


def check_device(sample, required):
    keys = ("device_completed_bangs", "device_scheduler_ns", "device_sync_batches", "device_rounds_submitted")
    if required:
        if any(type(sample.get(k)) is not int or sample[k] <= 0 for k in keys):
            raise RuntimeError("CPU fallback cannot satisfy the CUDA gate")
        bangs, scheduler, batches, rounds = (sample[k] for k in keys)
        if not bangs <= batches <= rounds <= 64 * batches or scheduler > sample["work_ns"]:
            raise RuntimeError("Invalid synchronized CUDA evidence")
    elif any(sample.get(k, 0) for k in keys):
        raise RuntimeError("CPU gate unexpectedly executed a GPU bang")


def ordered_variants(repetition):
    return ("baseline", "candidate") if repetition % 2 == 0 else ("candidate", "baseline")


def observation(differences, floor):
    """Deterministic paired bootstrap; tolerance policy is separate from parity."""
    rng = random.Random(7391)
    medians = sorted(statistics.median(rng.choices(differences, k=len(differences))) for _ in range(1000))
    low, high = medians[24], medians[974]
    classification = ("faster" if high < -floor else "slower" if low > floor else
        "indistinguishable_within_measured_uncertainty" if low <= 0 <= high else "inconclusive")
    return {"median_difference_ns": statistics.median(differences),
            "paired_difference_bootstrap95_ns": [low, high], "classification": classification,
            "uncertainty_method": "1000 paired resamples, seed 7391; signed CI crossing zero denotes observed uncertainty; nonzero differences below the configured floor remain inconclusive"}


def paired_gate(records, maximum, selected_metrics=None, noise_floor_ns=0):
    groups = {}
    for r in records:
        key = (r["workload"], r["mode"], r["lifetime"], r["backend"], r["threads"])
        pair = groups.setdefault(key, {})
        if r["variant"] in pair:
            raise RuntimeError("Duplicate benchmark variant")
        pair[r["variant"]] = r
    if not groups:
        raise RuntimeError("Missing benchmark coverage")
    comparisons = []
    for key, pair in groups.items():
        if set(pair) != {"baseline", "candidate"}:
            raise RuntimeError("Missing baseline/candidate measurements")
        base, new = pair["baseline"], pair["candidate"]
        if (not base["samples"] or len(base["samples"]) != len(new["samples"]) or
                len({s["repetition"] for s in base["samples"]}) != len(base["samples"])):
            raise RuntimeError("Missing or duplicate paired repetitions")
        metrics = selected_metrics or (["persistent_worker_latency_ns"] if key[2] == "persistent" else
            ["search_ns", "total_cost_ns"] if key[1] == "prepared" else
            ["work_ns"] if key[1] in ("batch", "ordinary-single") else ["total_cost_ns"])
        for metric in metrics:
            if any(type(s.get(metric)) not in (int, float) or not math.isfinite(s[metric])
                   or s[metric] < 0 for r in (base, new) for s in r["samples"]):
                raise RuntimeError(f"Missing or invalid required metric: {metric}")
            ratios = []
            excesses = []
            for b, c in zip(base["samples"], new["samples"]):
                if b["repetition"] != c["repetition"]:
                    raise RuntimeError("Unpaired benchmark repetitions")
                if b[metric] == c[metric] == 0:
                    continue
                ratios.append(c[metric] / b[metric] if b[metric] else math.inf)
                excesses.append(c[metric] - maximum * b[metric])
            if not ratios:
                raise RuntimeError(f"No nonzero samples for required metric: {metric}")
            ratio = statistics.median(ratios)
            comparisons.append({"workload": key[0], "mode": key[1], "lifetime": key[2],
                "backend": key[3], "threads": key[4], "metric": metric,
                "candidate_over_baseline": ratio if math.isfinite(ratio) else None,
                "median_excess_ns": statistics.median(excesses), "noise_floor_ns": noise_floor_ns,
                "passed": statistics.median(excesses) <= noise_floor_ns,
                "paired_ratios": [r if math.isfinite(r) else None for r in ratios],
                **observation([c[metric] - b[metric] for b, c in zip(base["samples"], new["samples"])], noise_floor_ns)})
    return comparisons


def write_results(output, document):
    (output / "results.json").write_text(json.dumps(document, indent=2, allow_nan=False) + "\n")
    rows = []
    for record in [*document["records"], *document.get("references", [])]:
        row = {key: record[key] for key in ("workload", "variant", "mode", "lifetime", "backend", "threads", "batch_size")}
        row.update({key: value["median"] for key, value in record["summary"].items()})
        rows.append(row)
    if rows:
        columns = list(rows[0]) + sorted(set().union(*(r.keys() for r in rows)) - set(rows[0]))
        with (output / "summary.csv").open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns)
            writer.writeheader()
            writer.writerows(rows)


def parser(device):
    p = argparse.ArgumentParser(description="Paired correctness/performance gates; generated artifacts stay in temporary directories")
    p.add_argument("--baseline", type=Path, default=ROOT, help="Baseline source checkout (default: current checkout)")
    p.add_argument("--candidate", type=Path, default=ROOT, help="Candidate source checkout (default: current checkout)")
    p.add_argument("--mode", action="append", choices=("batch", "phases", "prepared", "ordinary-single",
        "string-single", "string-batch", "string-serial-batch", "ordinary-worker-single", "ordinary-worker-batch",
        "owned-worker-single", "owned-worker-batch", "compatible-worker-single", "compatible-worker-batch"),
        help="Select gate execution boundary; repeatable. Default retains legacy controls")
    p.add_argument("--family", action="append", help="Seeded production family NAME:LENGTH; repeatable")
    p.add_argument("--configuration", action="append", help="Family configuration MODE:TASK:K:CIGAR, e.g. NW:PATH:2:EXTENDED; repeatable")
    p.add_argument("--seed", type=int, default=4862)
    p.add_argument("--shards", type=int, choices=(1, 2, 4), help="Requested owners (default: runtime threads)")
    p.add_argument("--bend", default="bend", help="One pinned Bend compiler for both source trees")
    for variant in ("baseline", "candidate"):
        p.add_argument(f"--{variant}-bend", help=f"Separate {variant} Bend executable (pin enforced by default)")
        p.add_argument(f"--{variant}-bend-version", help="Expected release for an intentional compiler override; requires the corresponding executable")
    p.add_argument("--corpus", type=Path, default=ROOT / "benchmarks/corpus.json")
    p.add_argument("--output", type=Path, help="Fresh result directory under the system temporary directory")
    p.add_argument("--threads", nargs="+", type=int, default=[1] if device else [1, 4])
    p.add_argument("--cpus", help="Ordered, distinct allowed logical CPUs; first N are used for N threads")
    p.add_argument("--batch-sizes", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64, 128, 256, 512] if device else [1, 16])
    p.add_argument("--batch-size", type=int, help="Shorthand for --batch-sizes 1 N")
    p.add_argument("--reuse-counts", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64])
    p.add_argument("--case", action="append", help="Select existing corpus cases; additions remain enabled")
    p.add_argument("--workload", action="append", help="Exact generated workload name, e.g. repeated/4; repeatable")
    p.add_argument("--repeats", type=int, default=7)
    p.add_argument("--warmups", type=int, default=2)
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--max-regression", type=float, default=1.10, help="Maximum median paired candidate/baseline ratio")
    p.add_argument("--noise-floor-ns", type=int, default=50000,
                   help="Additive tolerance for paired timing noise (default: 50 microseconds)")
    p.add_argument("--gate-metric", action="append", choices=(*PHASES, "startup_ns", "total_cost_ns", "persistent_worker_latency_ns", "end_to_end_ns",
        "call_ns", "native_api_ns", "native_serialization_ns", "total_with_prepare_ns", "amortized_per_target_ns", "validation_ns"))
    p.add_argument("--cflags", default="-std=c2x -O3 -pthread", help="Identical C options for baseline and candidate")
    p.add_argument("--baseline-cflags", help="Override C options for the baseline build")
    p.add_argument("--candidate-cflags", help="Override C options for the candidate build")
    p.add_argument("--allocations", action="store_true", help="Separate untimed CPU allocation diagnostics")
    p.add_argument("--edlib-u32", action="store_true", help="Add separately labeled temporary U32 Edlib diagnostics (production gate only)")
    if device:
        p.add_argument("--heap", default="1GB")
        p.add_argument("--check-build", action="store_true", help="Build and validate one real CUDA batch for both source trees")
    return p


def main(argv=None, *, device=False):
    from benchmarks.runner import load_corpus, summarize
    p = parser(device)
    args = p.parse_args(argv)
    if args.edlib_u32 and (device or not (args.mode or args.family)):
        p.error("--edlib-u32 requires an explicit CPU production mode or family")
    if platform.system() != "Linux":
        p.error("Run through the Linux/WSL benchmark entry point")
    original = os.sched_getaffinity(0)
    try:
        cpus = list(map(int, args.cpus.split(","))) if args.cpus else physical_cpus(original)
    except ValueError:
        p.error("--cpus requires comma-separated integers")
    threads = sorted(set(args.threads))
    args.threads = threads
    sizes = sorted(set([1, args.batch_size] if args.batch_size is not None else args.batch_sizes))
    reuses = sorted(set(args.reuse_counts))
    if (not cpus or len(set(cpus)) != len(cpus) or not set(cpus) <= original or
            not threads or min(threads) < 1 or max(threads) > min(len(cpus), 128) or
            args.repeats < 1 or args.warmups < 0 or not math.isfinite(args.timeout) or args.timeout <= 0 or
            not math.isfinite(args.max_regression) or args.max_regression <= 0 or args.noise_floor_ns < 0 or
            not sizes or not reuses or min(sizes) < 0 or min(reuses) < 1 or max(sizes + reuses) > 512):
        p.error("Invalid affinity, thread, repetition, timeout, regression ratio or batch/reuse count")
    if len(physical_cpus(cpus)) != len(cpus):
        p.error("--cpus must select distinct physical cores, not SMT siblings")
    if device:
        import re
        if not re.fullmatch(r"[1-9][0-9]*(?:MB|GB)", args.heap):
            p.error("--heap must be a positive integer followed by MB or GB")
    corpus = load_corpus(args.corpus)
    if args.case:
        if set(args.case) - {c["name"] for c in corpus["cases"]}:
            p.error("Unknown --case")
        corpus = {**corpus, "cases": [c for c in corpus["cases"] if c["name"] in args.case]}
    suite = workloads(corpus, sizes, reuses)
    if args.family:
        from benchmarks.production_workloads import family
        suite = []
        for specification in args.family:
            try:
                name, length = specification.split(":")
                length = int(length)
                for count in sizes:
                    query, config, batches = family(name, length, count, args.seed)
                    configurations = [("", config)]
                    if args.configuration:
                        configurations = []
                        for specification in args.configuration:
                            mode, task, limit, format = specification.split(":")
                            limit = int(limit)
                            configured = AlignConfig(Mode(mode), Task(task), Unlimited() if limit < 0 else MaxDistance(limit),
                                config.equalities, CigarFormat(format))
                            configurations.append(("/" + specification, configured))
                    for suffix, configured in configurations:
                        configured_batches = tuple(tuple((q, t, configured) for q, t, _ in batch) for batch in batches)
                        for reuse in reuses:
                            suite.append(Workload(f"{name}-{length}/{count}/r{reuse}{suffix}", configured_batches[0],
                                batches=configured_batches, reuse_count=reuse, prepared_query=(query, configured), seed=args.seed))
            except ValueError as error:
                p.error(str(error))
    elif args.configuration:
        p.error("--configuration requires --family")
    if args.workload:
        if set(args.workload) - {w.name for w in suite}:
            p.error("Unknown --workload")
        suite = [w for w in suite if w.name in args.workload]
    if device and args.check_build:
        suite = [Workload("device-smoke", ((b"kitten", b"sitting", AlignConfig()),), (3,))]
    for w in suite:
        if w.reuse:
            validate_prepared(w.jobs)
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="bend-gate-results-"))
    if not output.is_relative_to(Path(tempfile.gettempdir()).resolve()) or output.is_relative_to(ROOT):
        p.error("--output must be outside the repository and inside the system temporary directory")
    if args.output:
        if output.exists():
            p.error("Output already exists; choose a fresh temporary directory")
        output.mkdir(parents=True)
    print(f"Gate results: {output}", flush=True)
    document = {"schema": 3, "status": "unvalidated", "records": [], "comparisons": [], "allocations": [],
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "options": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        "environment": {"platform": platform.platform(), "python": platform.python_version(),
            "available_cpus": sorted(original), "selected_cpus": cpus,
            "corpus_sha256": digest(args.corpus.read_bytes()), "runtime_environment": {
                k: reproducible_env()[k] for k in ("BENDRTS", "BEND_NO_TELEMETRY")}},
        "phase_semantics": {"batch": "Batch.prepare / execute / ordered, measured with forced boundaries",
            "phases": "LEGACY V.build_peq / M.search_profiles serial diagnostic composition of Myers profile/search and configured result restoration; not public batch throughput",
            "reconstruction_ns": "PATH reconstruction only; validation and CIGAR are in result_ns",
            "locations_ns": "Location restoration and threshold acceptance; HW includes reversed profile and start searches",
            "prepared": "LEGACY V.build_peq / M.search_profiles: one NW profile per request, reused by identical query/config with varying targets",
            "total_cost_ns": "Sum of measured compute phases including profile and input preparation, excluding serialization",
            "startup_ns": "Popen start to native monotonic ready handshake, before argument/input decoding",
            "persistent_worker_latency_ns": "Pre-encoded request write to complete response bytes on an initialized worker; decoding/validation excluded",
            "allocations": "Separate CPU diagnostic binary; heap_alloc calls after input decoding, not allocated bytes or peak live memory"}}
    frames = {digest(encode_request(*job)): encode_request(*job).hex() for w in suite for job in w.jobs}
    document["inputs"] = frames
    document["workloads"] = [{"name": w.name, "input_sha256": digest(w.payload), "reuse": w.reuse,
        "jobs": [digest(encode_request(*j)) for j in w.jobs], "known_distances": w.distances} for w in suite]
    document["suite_sha256"] = digest(json.dumps(document["workloads"], sort_keys=True).encode())
    try:
        cc = compiler_command(os.environ.get("CC", "clang-19"))
        cxx = compiler_command(os.environ.get("CXX", "g++"))
        compilers = select_compilers(args)
        bends = {v: Path(info["path"]) for v, info in compilers.items()}
        document["environment"].update(bend_compilers=compilers,
            cc=run_command([*cc, "--version"]), cxx=run_command([*cxx, "--version"]),
            cpu_topology=run_command(["lscpu", "-p=CPU,CORE,SOCKET"]),
            git_commit=run_command(["git", "-C", ROOT, "rev-parse", "HEAD"]))
        if bends["baseline"] == bends["candidate"]:
            document["environment"].update(bend=compilers["baseline"]["version"],
                                           bend_sha256=compilers["baseline"]["sha256"])
        if device:
            from benchmarks.gpu_runner import prerequisites
            cuda, _, problems = prerequisites(cc)
            if problems:
                raise RuntimeError("; ".join(problems))
            os.environ["CUDA_HOME"] = str(cuda)
            document["environment"]["nvidia_smi"] = run_command(["nvidia-smi", "--query-gpu=name,uuid,driver_version,memory.total", "--format=csv,noheader"])
        from benchmarks.production_gate import provenance, run as run_production
        document["provenance"] = provenance(args, cc, cxx, compilers)
        if args.mode or args.family:
            if device:
                raise ValueError("Explicit production modes currently require the CPU gate")
            run_production(args, document, suite, cpus, bends, cc, cxx, output)
            write_results(output, document)
            return int(document["status"] != "passed")
        with tempfile.TemporaryDirectory(prefix="bend-gate-build-") as temporary:
            scratch = Path(temporary)
            binaries, document["builds"] = {}, {}
            kinds = ["cpu", *( ["cuda"] if device else []), *( ["allocations"] if args.allocations else [])]
            for variant, root in (("baseline", args.baseline), ("candidate", args.candidate)):
                override = args.baseline_cflags if variant == "baseline" else args.candidate_cflags
                flags = shlex.split(args.cflags if override is None else override)
                for kind in kinds:
                    print(f"Building {variant} {kind}...", flush=True)
                    binary, metadata = build(root.resolve(), scratch / variant / kind, bends[variant], cc,
                        flags, device=kind == "cuda", allocations=kind == "allocations",
                        compiler_identity=compilers[variant])
                    binaries[variant, kind] = binary
                    document["builds"][variant + "/" + kind] = metadata
            source = ROOT / "vendor/edlib/edlib"
            oracle = scratch / "edlib"
            argv = [*cxx, "-std=c++14", "-O3", "-DNDEBUG", "-I", source / "include",
                    ROOT / "tests/edlib_oracle.cpp", source / "src/edlib.cpp", "-o", oracle]
            run_command(argv)
            document["oracle"] = {"command": list(map(str, argv)), "binary_sha256": digest(oracle.read_bytes()),
                "sources_sha256": {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in
                    (ROOT / "tests/edlib_oracle.cpp", ROOT / "src/transport.c", source / "src/edlib.cpp", source / "include/edlib.h")}}
            for w in suite:
                payload = w.payload
                from benchmarks.gpu_runner import decode_batch
                with affinity(cpus[:1]):
                    reference = subprocess.run([str(oracle), "--worker"], input=payload, capture_output=True,
                        timeout=args.timeout, env=reproducible_env())
                if reference.returncode or reference.stderr:
                    raise RuntimeError(f"Edlib oracle failed: {reference.stderr.decode(errors='replace')}")
                expected = decode_batch(reference.stdout, len(w.jobs))
                validate(expected, expected, w)
                canonical = None
                modes = ["batch"] if device and args.check_build else ["batch", "phases", *( ["prepared"] if w.reuse else [])]
                for thread in threads:
                    with affinity(cpus[:thread]):
                        for mode in modes:
                            backends = ["cpu", "cuda"] if device and mode == "batch" else ["cpu"]
                            for backend in backends:
                                for lifetime in ("fresh", "persistent"):
                                    records, persistent = {}, {}
                                    rounds = args.warmups + args.repeats
                                    for variant in ordered_variants(0):
                                        records[variant] = {"workload": w.name, "variant": variant, "mode": mode,
                                            "lifetime": lifetime, "backend": backend, "threads": thread,
                                            "batch_size": len(w.jobs), "affinity_cpus": cpus[:thread],
                                            "input_sha256": digest(payload), "samples": []}
                                    with ExitStack() as stack:
                                        if lifetime == "persistent":
                                            for variant in ordered_variants(0):
                                                argv = [binaries[variant, backend], *runtime_prefix(threads=thread,
                                                    gpu=args.heap if backend == "cuda" else "off"), mode, len(w.jobs), rounds]
                                                started = time.monotonic_ns()
                                                worker = Worker(argv, args.timeout)
                                                stack.callback(worker.close)
                                                records[variant]["worker_startup"] = worker.ready(started)
                                                persistent[variant] = worker
                                        for repeat in range(rounds):
                                            pair = {}
                                            for order, variant in enumerate(ordered_variants(repeat)):
                                                started = time.monotonic_ns()
                                                if lifetime == "fresh":
                                                    argv = [binaries[variant, backend], *runtime_prefix(threads=thread,
                                                        gpu=args.heap if backend == "cuda" else "off"), mode, len(w.jobs), 1]
                                                    worker = Worker(argv, args.timeout)
                                                    try:
                                                        startup = worker.ready(started)
                                                        values, sample = worker.request(payload, len(w.jobs))
                                                        worker.finish()
                                                        sample["end_to_end_ns"] = time.monotonic_ns() - started
                                                        sample.update(startup)
                                                    finally:
                                                        worker.close()
                                                else:
                                                    values, sample = persistent[variant].request(payload, len(w.jobs))
                                                    sample["persistent_worker_latency_ns"] = sample["request_latency_ns"]
                                                if "heap_alloc_calls" in sample:
                                                    raise RuntimeError("Allocation instrumentation entered a timed binary")
                                                check_device(sample, backend == "cuda")
                                                validate(values, expected, w)
                                                if canonical is None:
                                                    canonical = values
                                                validate(values, canonical, w, exact=True)
                                                pair[variant] = values
                                                sample.update(repetition=repeat - args.warmups, order=order)
                                                if repeat >= args.warmups:
                                                    records[variant]["samples"].append(sample)
                                            validate(pair["candidate"], pair["baseline"], w, exact=True)
                                        for worker in persistent.values():
                                            worker.finish()
                                    for record in records.values():
                                        record["summary"] = summarize(record["samples"])
                                        document["records"].append(record)
                        if args.allocations:
                            for variant in ordered_variants(0):
                                argv = [binaries[variant, "allocations"], *runtime_prefix(threads=thread, gpu="off"), "batch", len(w.jobs), 1]
                                started = time.monotonic_ns()
                                worker = Worker(argv, args.timeout)
                                try:
                                    worker.ready(started)
                                    values, metrics = worker.request(payload, len(w.jobs))
                                    validate(values, expected, w)
                                    worker.finish()
                                finally:
                                    worker.close()
                                count = metrics.get("heap_alloc_calls")
                                if type(count) is not int or count < 0:
                                    raise RuntimeError("Missing allocation diagnostic")
                                document["allocations"].append({"variant": variant, "workload": w.name,
                                    "threads": thread, "heap_alloc_calls": count, "output_sha256": metrics["output_sha256"]})
                print(f"Validated and measured {w.name}", flush=True)
            document["comparisons"] = paired_gate(document["records"], args.max_regression, args.gate_metric, args.noise_floor_ns)
            if not document["comparisons"]:
                raise RuntimeError("No applicable nonzero performance metrics were gated")
            document["status"] = "passed" if all(c["passed"] for c in document["comparisons"]) else "performance_regression"
    except BaseException as error:
        document["status"] = "failed"
        document["reason"] = str(error)
        raise
    finally:
        write_results(output, document)
    failures = sum(not c["passed"] for c in document["comparisons"])
    print(f"{document['status']}: {len(document['comparisons'])} comparisons, {failures} regressions. Results: {output}", flush=True)
    return int(bool(failures))
