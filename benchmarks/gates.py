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


@dataclass(frozen=True)
class Workload:
    name: str
    jobs: tuple
    distances: tuple | None = None
    reuse: bool = False

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
        validate_path(job, actual)
        validate_path(job, oracle)
        if exact and actual != oracle:
            raise RuntimeError(f"Complete baseline/candidate result mismatch: {workload.name}, job {i}")
        if workload.distances is not None and actual.edit_distance != workload.distances[i]:
            raise RuntimeError(f"Corpus distance mismatch: {workload.name}, job {i}")


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
        if not line.startswith(READY):
            raise RuntimeError(f"Missing benchmark startup handshake: {line!r}")
        ready = int(line[len(READY):])
        observed = time.monotonic_ns()
        if not started <= ready <= observed:
            raise RuntimeError("Benchmark clocks do not share an epoch")
        return {"startup_ns": ready - started, "startup_handshake_ns": observed - started}

    def request(self, payload, count, *, metrics=True):
        self.deadline = time.monotonic() + self.timeout
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
            sample["amortized_total_ns"] = sample["total_cost_ns"] / count
            sample["search_per_query_ns"] = sample["search_ns"] / count
        return [decode_response(frame) for frame in values], sample

    def finish(self):
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=self.timeout)
            # Exact count, no trailing result or diagnostic can go unchecked.
            extra = self.process.stdout.read() or b""
            error = self.process.stderr.read() or b""
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
    for name in ("gate_probe.bend", "gate_metrics.bend", "gate_metrics.c"):
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


def build(root, directory, bend, cc, flags, *, device=False, allocations=False):
    from benchmarks.gpu_runner import instrument, prerequisites, require_gpu_build
    hashes = snapshot(root, directory / "source")
    entry = directory / "source/benchmarks/gate_probe.bend"
    if device:
        text = entry.read_text()
        if text.count("  B.execute(plan)") != 1:
            raise RuntimeError("Review GPU benchmark entry substitution")
        entry.write_text(text.replace("  B.execute(plan)", "  B.execute!(plan)"))
    hashes["benchmarks/gate_probe.bend"] = digest(entry.read_bytes())
    source, binary = directory / "probe.c", directory / "probe"
    commands = [[bend, entry, "-o", source]]
    run_command(commands[0])
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
    run_command(argv)
    metadata = {"sources_sha256": hashes, "emitted_c_sha256": digest(source.read_bytes()),
        "binary_sha256": digest(binary.read_bytes()), "allocations": allocations,
        "commands": [list(map(str, cmd)) for cmd in commands]}
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


def paired_gate(records, maximum, selected_metrics=None, noise_floor_ns=0):
    groups = {}
    for r in records:
        key = (r["workload"], r["mode"], r["lifetime"], r["backend"], r["threads"])
        groups.setdefault(key, {})[r["variant"]] = r
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
            ["work_ns"] if key[1] == "batch" else ["total_cost_ns"])
        for metric in metrics:
            if metric not in base["samples"][0]:
                continue
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
                continue
            ratio = statistics.median(ratios)
            comparisons.append({"workload": key[0], "mode": key[1], "lifetime": key[2],
                "backend": key[3], "threads": key[4], "metric": metric,
                "candidate_over_baseline": ratio if math.isfinite(ratio) else None,
                "median_excess_ns": statistics.median(excesses), "noise_floor_ns": noise_floor_ns,
                "passed": statistics.median(excesses) <= noise_floor_ns,
                "paired_ratios": [r if math.isfinite(r) else None for r in ratios]})
    return comparisons


def write_results(output, document):
    (output / "results.json").write_text(json.dumps(document, indent=2, allow_nan=False) + "\n")
    rows = []
    for record in document["records"]:
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
    p.add_argument("--bend", default="bend", help="One pinned Bend compiler for both source trees")
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
    p.add_argument("--gate-metric", action="append", choices=(*PHASES, "startup_ns", "total_cost_ns", "persistent_worker_latency_ns", "end_to_end_ns"))
    p.add_argument("--cflags", default="-std=c2x -O3 -pthread", help="Identical C options for baseline and candidate")
    p.add_argument("--allocations", action="store_true", help="Separate untimed CPU allocation diagnostics")
    if device:
        p.add_argument("--heap", default="1GB")
        p.add_argument("--check-build", action="store_true", help="Build and validate one real CUDA batch for both source trees")
    return p


def main(argv=None, *, device=False):
    from benchmarks.runner import load_corpus, summarize
    p = parser(device)
    args = p.parse_args(argv)
    if platform.system() != "Linux":
        p.error("Run through the Linux/WSL benchmark entry point")
    original = os.sched_getaffinity(0)
    try:
        cpus = list(map(int, args.cpus.split(","))) if args.cpus else sorted(original)
    except ValueError:
        p.error("--cpus requires comma-separated integers")
    threads = sorted(set(args.threads))
    sizes = sorted(set([1, args.batch_size] if args.batch_size is not None else args.batch_sizes))
    reuses = sorted(set(args.reuse_counts))
    if (not cpus or len(set(cpus)) != len(cpus) or not set(cpus) <= original or
            not threads or min(threads) < 1 or max(threads) > min(len(cpus), 128) or
            args.repeats < 1 or args.warmups < 0 or not math.isfinite(args.timeout) or args.timeout <= 0 or
            not math.isfinite(args.max_regression) or args.max_regression <= 0 or args.noise_floor_ns < 0 or
            not sizes or not reuses or min(sizes + reuses) < 1 or max(sizes + reuses) > 512):
        p.error("Invalid affinity, thread, repetition, timeout, regression ratio or batch/reuse count")
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
            "phases": "Serial diagnostic composition of Myers profile/search and configured result restoration; not public batch throughput",
            "reconstruction_ns": "PATH reconstruction only; validation and CIGAR are in result_ns",
            "locations_ns": "Location restoration and threshold acceptance; HW includes reversed profile and start searches",
            "prepared": "One NW profile per request, reused by identical query/config with varying targets",
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
        cc = shlex.split(os.environ.get("CC", "clang-19"))
        cxx = shlex.split(os.environ.get("CXX", "g++"))
        bend = Path(shutil.which(args.bend) or args.bend).resolve()
        version = run_command([bend, "version"])
        for root in (args.baseline, args.candidate):
            if version != "bend " + (root / ".bend-version").read_text().strip():
                raise RuntimeError(f"Source pin disagrees with the common compiler: {root}")
        document["environment"].update(bend=version, bend_sha256=digest(bend.read_bytes()),
            cc=run_command([*cc, "--version"]), cxx=run_command([*cxx, "--version"]),
            cpu_topology=run_command(["lscpu", "-p=CPU,CORE,SOCKET"]),
            git_commit=run_command(["git", "-C", ROOT, "rev-parse", "HEAD"]))
        if device:
            from benchmarks.gpu_runner import prerequisites
            cuda, _, problems = prerequisites(cc)
            if problems:
                raise RuntimeError("; ".join(problems))
            os.environ["CUDA_HOME"] = str(cuda)
            document["environment"]["nvidia_smi"] = run_command(["nvidia-smi", "--query-gpu=name,uuid,driver_version,memory.total", "--format=csv,noheader"])
        with tempfile.TemporaryDirectory(prefix="bend-gate-build-") as temporary:
            scratch = Path(temporary)
            binaries, document["builds"] = {}, {}
            kinds = ["cpu", *( ["cuda"] if device else []), *( ["allocations"] if args.allocations else [])]
            for variant, root in (("baseline", args.baseline), ("candidate", args.candidate)):
                for kind in kinds:
                    print(f"Building {variant} {kind}...", flush=True)
                    binary, metadata = build(root.resolve(), scratch / variant / kind, bend, cc,
                        shlex.split(args.cflags), device=kind == "cuda", allocations=kind == "allocations")
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
