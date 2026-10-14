"""No third-party Python dependencies. Linux wait4 supplies per-process peak RSS."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shlex
import signal
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/benchmarks"
PHASES = {0: "transport", 1: "prepare", 2: "profile", 3: "work", 4: "release"}


def command(argv, *, timeout=180):
    result = subprocess.run([str(x) for x in argv], cwd=ROOT, capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{argv!r} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_command():
    # Windows linked-worktree metadata remains unchanged; only translate it.
    dotgit = ROOT / ".git"
    if dotgit.is_file():
        gitdir = dotgit.read_text().strip().removeprefix("gitdir: ")
        if len(gitdir) > 2 and gitdir[1] == ":":
            gitdir = command(["wslpath", "-u", gitdir])
            return ["git", f"--git-dir={gitdir}", f"--work-tree={ROOT}"]
    return ["git", "-C", str(ROOT)]


def load_corpus(path):
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != 1 or not document.get("cases"):
        raise ValueError("Unsupported or empty corpus")
    seen = set()
    for case in document["cases"]:
        name = case["name"]
        if not isinstance(name, str) or not name or name in seen:
            raise ValueError("Corpus names must be unique nonempty strings")
        seen.add(name)
        for key in ("query", "target"):
            text = case[key]
            if not isinstance(text, str) or not text.isascii() or "\0" in text or len(text) > 4096:
                raise ValueError(f"Unsupported {key} in {name}")
        value = case["distance"]
        if type(value) is not int or not abs(len(case["query"]) - len(case["target"])) <= value <= max(
                len(case["query"]), len(case["target"])):
            raise ValueError(f"Invalid expected distance in {name}")
    return document


def build(cxx):
    BUILD.mkdir(parents=True, exist_ok=True)
    version = command(["bend", "version"])
    if version != "bend " + (ROOT / ".bend-version").read_text().strip():
        raise RuntimeError(f"Unexpected compiler: {version}; run scripts/setup.sh --native-only")
    source = ROOT / "vendor/edlib/edlib"
    if not (source / "src/edlib.cpp").is_file():
        raise RuntimeError("Missing Edlib submodule; run scripts/setup.sh --native-only")
    commands = [
        ["clang", "-std=c11", "-O2", ROOT / "benchmarks/launch.c", "-o", BUILD / "launch"],
        ["bend", ROOT / "benchmarks/bend.bend", "-o", BUILD / "bend"],
        [*cxx, "-std=c++14", "-O2", "-DNDEBUG", "-I", source / "include",
         ROOT / "benchmarks/edlib.cpp", "-o", BUILD / "edlib"],
    ]
    builds = []
    for argv in commands:
        started = time.monotonic_ns()
        command(argv)
        builds.append({"argv": list(map(str, argv)), "wall_ns": time.monotonic_ns() - started})
    return version, builds


def parse_output(text):
    ready = checksum = usage = None
    phases = {}
    for line in text.splitlines():
        fields = line.split(",")
        if len(fields) == 2 and fields[0] == "ready" and ready is None:
            ready = int(fields[1])
        elif len(fields) == 2 and fields[0] == "checksum" and checksum is None:
            checksum = int(fields[1])
        elif len(fields) == 3 and fields[0] == "phase" and int(fields[1]) not in phases:
            phases[int(fields[1])] = int(fields[2])
        elif len(fields) == 5 and fields[0] == "usage" and usage is None:
            usage = list(map(int, fields[1:]))
        else:
            raise RuntimeError(f"Malformed benchmark output: {line!r}")
    if ready is None or checksum is None or usage is None or set(phases) != set(range(8)) or any(n < 0 for n in phases.values()):
        raise RuntimeError(f"Incomplete benchmark output: {text!r}")
    return ready, checksum, phases, usage


def measure(argv, timeout):
    # The native launcher obtains RSS for its child; Python's own peak and the
    # launcher's peak are excluded. Pin the parent; both children inherit.
    def expired(signum, frame):
        raise TimeoutError(f"Benchmark exceeded {timeout}s: {argv[:6]!r}")

    old_handler = signal.signal(signal.SIGALRM, expired)
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        started = time.monotonic_ns()
        process = subprocess.Popen([str(BUILD / "launch"), *map(str, argv)], stdout=stdout,
                                   stderr=stderr, start_new_session=True)
        signal.setitimer(signal.ITIMER_REAL, timeout)
        try:
            _, status, usage = os.wait4(process.pid, 0)
            ended = time.monotonic_ns()
            process.returncode = os.waitstatus_to_exitcode(status)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            _, status, _ = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            raise
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old_handler)
        stdout.seek(0); stderr.seek(0)
        text, error = stdout.read().decode(), stderr.read().decode()
    if process.returncode:
        raise RuntimeError(f"Native benchmark exited {process.returncode}: {error}\n{text}")
    ready, checksum, phases, usage = parse_output(text)
    spawned, native_ended, rss, cpu_ns = usage
    if not started <= spawned <= ready <= native_ended <= ended:
        raise RuntimeError("Native/Python monotonic clocks do not share an epoch")
    return {"startup_ns": ready - started, "end_to_end_ns": ended - started,
            "launcher_ns": spawned - started, "native_startup_ns": ready - spawned,
            "native_wall_ns": native_ended - spawned, "peak_rss_kib": rss, "cpu_ns": cpu_ns,
            "checksum": checksum, **{name + "_ns": phases[index] for index, name in PHASES.items()}}


def lookup_checksum(case, count, *, tree):
    query, target = case["query"], case["target"]
    if len(query) > len(target):
        query, target = target, query
    total = 0
    for start in range(0, len(query), 32):
        word = query[start:start + 32]
        padding = (0xffffffff << len(word)) & 0xffffffff
        masks = {}
        for i, symbol in enumerate(word):
            masks[symbol] = masks.get(symbol, 0) | (1 << i)
        for c in target:
            total += (padding | masks.get(c, 0)) if tree else ord(c)
    return (total * count) & 0xffffffff


def summarize(samples):
    metrics = [key for key in samples[0] if key.endswith("_ns") or key == "peak_rss_kib"]
    summary = {}
    for metric in metrics:
        values = sorted(sample[metric] for sample in samples)
        summary[metric] = {"median": statistics.median(values), "min": values[0],
                           "max": values[-1], "p95": values[math.ceil(.95 * len(values)) - 1]}
    return summary


def environment(version, cxx, builds, args):
    git = git_command()
    status = command([*git, "status", "--porcelain", "--untracked-files=normal"])
    sources = [
        "main.bend", "worker.bend", "gpu_batch.bend", "lib.bend", "EdlibTypes.bend", "GpuBatch.bend",
        "src/Myers.bend", "src/Alignment.bend", "src/Reconstruction.bend", "src/DistanceDP.bend",
        "src/Sequence.bend", "src/Batch.bend", "src/Cli.bend", "src/ByteProtocol.bend", "src/Transport.bend", "src/transport.c",
        ".bend-version", "run_benchmarks.py", "benchmarks/bend.bend", "benchmarks/timer.bend",
        "benchmarks/timer.c", "benchmarks/edlib.cpp", "benchmarks/launch.c", "benchmarks/runner.py",
        "benchmarks/generate.py", "vendor/edlib/edlib/src/edlib.cpp", "vendor/edlib/edlib/include/edlib.h",
    ]
    cpu = json.loads(command(["lscpu", "-J"]))["lscpu"]
    keys = {"Architecture:", "CPU(s):", "Model name:", "Thread(s) per core:",
            "Core(s) per socket:", "Socket(s):", "Hypervisor vendor:", "Virtualization type:"}
    return {"bend": version, "cxx": command([*cxx, "--version"]).splitlines()[0],
            "clang": command(["clang", "--version"]).splitlines()[0], "python": platform.python_version(),
            "platform": platform.platform(), "os_release": Path("/etc/os-release").read_text(),
            "cpu": {r["field"]: r["data"] for r in cpu if r["field"] in keys},
            "available_cpus": sorted(os.sched_getaffinity(0)),
            "git_commit": command([*git, "rev-parse", "HEAD"]), "git_status": status,
            "tracked_diff_sha256": hashlib.sha256(command([*git, "diff", "HEAD"]).encode()).hexdigest(),
            "edlib_gitlink": command([*git, "ls-tree", "HEAD", "vendor/edlib"]),
            "source_sha256": {path: sha(ROOT / path) for path in sources},
            "binary_sha256": {name: sha(BUILD / name) for name in ("bend", "edlib", "launch")},
            "builds": builds, "arguments": vars(args),
            "clock": "CLOCK_MONOTONIC nanoseconds", "rss": "wait4 ru_maxrss, KiB, whole child process",
            "timer_resolution_seconds": time.get_clock_info("monotonic").resolution}


def write_report(output, document):
    output.mkdir(parents=True, exist_ok=True)
    (output / "results.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    columns = ["case", "algorithm", "threads", "batch_size", "mode", "query_length", "target_length",
               "distance", "launcher_ms", "native_startup_ms", "startup_ms", "transport_ms", "prepare_ms", "profile_ms", "work_ms",
               "release_ms", "end_to_end_ms", "cpu_ms", "peak_rss_kib", "work_per_pair_us",
               "native_wall_ms", "work_pairs_per_second", "end_to_end_pairs_per_second", "lookups_per_second"]
    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for record in document["records"]:
            med = {key: value["median"] for key, value in record["summary"].items()}
            row = {key: record[key] for key in columns[:8]}
            for metric in PHASES.values():
                row[metric + "_ms"] = med[metric + "_ns"] / 1e6
            for metric in ("launcher", "native_startup", "startup", "end_to_end", "native_wall", "cpu"):
                row[metric + "_ms"] = med[metric + "_ns"] / 1e6
            row["peak_rss_kib"] = med["peak_rss_kib"]
            row["work_per_pair_us"] = med["work_ns"] / record["batch_size"] / 1000
            # Only full/prepared do alignments. Lookup/scan throughput is a
            # synthetic traversal rate and must never be labeled alignments/s.
            if record["mode"] in ("full", "prepared"):
                row["work_pairs_per_second"] = record["batch_size"] * 1e9 / med["work_ns"] if med["work_ns"] else ""
                row["end_to_end_pairs_per_second"] = record["batch_size"] * 1e9 / med["end_to_end_ns"]
            elif record["mode"] == "lookup":
                row["lookups_per_second"] = record["lookup_count"] * 1e9 / med["work_ns"] if med["work_ns"] else ""
            writer.writerow(row)
    lines = ["# Native performance observation", "",
             f"Corpus SHA-256: `{document['corpus_sha256']}`. "
             f"{document['repeats']} measured runs after {document['warmups']} discarded warmups per workload.", "",
             "Wall times use median samples; Bend full uses the public align_batch API, including planning and ordering; "
             "full includes profile construction per pair, prepared reuses one profile. "
             "Edlib is single threaded. All distances/checksums were validated. Peak RSS covers the entire child process. "
             "E2E includes the native RSS launcher; launcher/native startup times are recorded separately.", "",
             "| Case | Workload | Bend threads | Bend work ms | Edlib work ms | Bend / Edlib | Bend E2E ms | Edlib E2E ms | Bend RSS KiB | Edlib RSS KiB |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    references = {(r["case"], r["mode"], r["batch_size"]): r for r in document["records"] if r["algorithm"] == "edlib"}
    for record in document["records"]:
        if record["algorithm"] != "bend" or record["mode"] not in ("full", "prepared"):
            continue
        reference = references[(record["case"], record["mode"], record["batch_size"])]
        b, e = record["summary"], reference["summary"]
        bn, en = b["work_ns"]["median"], e["work_ns"]["median"]
        lines.append(f"| {record['case']} | {record['mode']} × {record['batch_size']} | {record['threads']} | "
                     f"{bn / 1e6:.4f} | {en / 1e6:.4f} | {bn / en:.2f} | "
                     f"{b['end_to_end_ns']['median'] / 1e6:.3f} | {e['end_to_end_ns']['median'] / 1e6:.3f} | "
                     f"{b['peak_rss_kib']['median']:.0f} | {e['peak_rss_kib']['median']:.0f} |")
    lines.extend(["", "A ratio above 1 means Bend took longer. These observations establish no general speedup. "
                  "The corpus includes different similarity/alphabet/length regimes; do not combine them into a universal ratio.", "",
                  "Raw samples, dispersion, CPU affinity, source/binary hashes, build commands, tool versions and host details "
                  "are in results.json. summary.csv also contains phase timing, latency and throughput for every workload.", ""])
    (output / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Rebuild and benchmark native Bend versus pinned C++ Edlib")
    parser.add_argument("--corpus", default="benchmarks/corpus.json")
    parser.add_argument("--output", default="build/benchmarks/results")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=16, help="Power of two, 2..512")
    parser.add_argument("--threads", nargs="+", type=int, default=[1, 4], help="Always includes one core")
    parser.add_argument("--cpus", help="Comma-separated distinct allowed CPU IDs; default uses first allowed CPUs")
    parser.add_argument("--case", action="append", help="Select corpus case by exact name; repeatable")
    parser.add_argument("--timeout", type=float, default=120, help="Maximum seconds for one native process")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("Run through run_benchmarks.py on Windows/WSL or Linux")
    if args.repeats < 1 or args.warmups < 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("Invalid repetition, warmup or timeout count")
    if args.batch_size < 2 or args.batch_size > 512 or args.batch_size & (args.batch_size - 1):
        parser.error("--batch-size must be a power of two in 2..512")
    threads = sorted(set([1, *args.threads]))
    original_affinity = os.sched_getaffinity(0)
    cpus = list(map(int, args.cpus.split(","))) if args.cpus else sorted(original_affinity)
    if len(set(cpus)) != len(cpus) or not set(cpus) <= original_affinity or any(t < 1 or t > len(cpus) for t in threads):
        parser.error("Thread counts must fit the distinct available --cpus")
    corpus_path = ROOT / args.corpus
    corpus = load_corpus(corpus_path)
    cases = [c for c in corpus["cases"] if not args.case or c["name"] in args.case]
    if not cases or args.case and set(args.case) - {c["name"] for c in cases}:
        parser.error("Unknown --case")
    output = (ROOT / args.output).resolve()
    if output.exists() and any((output / name).exists() for name in ("results.json", "summary.csv", "REPORT.md")):
        parser.error("Output already contains a result; choose a fresh --output directory")
    cxx = shlex.split(os.environ.get("CXX", "g++"))
    print("Rebuilding benchmark executables...", flush=True)
    version, builds = build(cxx)
    document = {"schema": 1, "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "corpus_sha256": sha(corpus_path), "repeats": args.repeats, "warmups": args.warmups,
                "environment": environment(version, cxx, builds, args), "records": []}
    try:
        for case in cases:
            jobs = [(algorithm, thread, mode, count)
                    for algorithm, counts in [("edlib", [1]), ("bend", threads)]
                    for thread in counts for mode in ("full", "prepared") for count in (1, args.batch_size)]
            jobs += [("bend", thread, mode, args.batch_size) for thread in threads for mode in ("lookup", "scan")]
            records = {}
            for algorithm, thread, mode, count in jobs:
                record = {"case": case["name"], "algorithm": algorithm, "threads": thread,
                          "batch_size": count, "mode": mode, "query_length": len(case["query"]),
                          "target_length": len(case["target"]), "distance": case["distance"],
                          "affinity_cpus": cpus[:thread], "samples": []}
                record["expected_checksum"] = (lookup_checksum(case, count, tree=mode == "lookup") if mode in ("lookup", "scan")
                                                else case["distance"] * count)
                if mode in ("lookup", "scan"):
                    record["lookup_count"] = count * len(max((case["query"], case["target"]), key=len)) * math.ceil(
                        min(len(case["query"]), len(case["target"])) / 32)
                records[(algorithm, thread, mode, count)] = record
            for repetition in range(args.warmups + args.repeats):
                # Rotate algorithm/thread/mode order across warmups and samples.
                offset = repetition % len(jobs)
                for job in jobs[offset:] + jobs[:offset]:
                    algorithm, thread, mode, count = job
                    os.sched_setaffinity(0, cpus[:thread])
                    argv = [BUILD / algorithm]
                    if algorithm == "bend":
                        argv += ["--threads", str(thread), "--"]
                    argv += [mode, str(count.bit_length()), case["query"], case["target"]]
                    sample = measure(argv, args.timeout)
                    expected = records[job]["expected_checksum"]
                    if sample["checksum"] != expected:
                        raise RuntimeError(f"Checksum mismatch: {case['name']} {job}: {sample['checksum']} != {expected}")
                    if repetition >= args.warmups:
                        sample["repetition"] = repetition - args.warmups
                        records[job]["samples"].append(sample)
            for record in records.values():
                record["summary"] = summarize(record["samples"])
                document["records"].append(record)
            print(f"Validated and measured {case['name']} ({len(jobs)} workloads)", flush=True)
    finally:
        os.sched_setaffinity(0, original_affinity)
    write_report(output, document)
    print(f"Wrote {output / 'REPORT.md'} and raw results.json / summary.csv", flush=True)
    return 0
