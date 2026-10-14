"""Compare two Bend releases on identical CPU batch plans (Linux/WSL).

Run as python3 -m benchmarks.compare_toolchains --help. Compiler installs and
the project pin are never modified. Every sample checks full ordered results
against pinned Edlib, plus the corpus's independent DP distances.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import time

from alignment import AlignConfig
from benchmarks.gpu_runner import decode_batch, instrument, parse_metrics
from benchmarks.runner import ROOT, command, git_command, load_corpus, sha, summarize
from transport import encode_request


def workloads(corpus):
    cases = {case["name"]: case for case in corpus["cases"]}
    names = ("dna-similar-512", "dna-random-512", "dna-random-4096")
    sets = [(name, "demand", [name] * 32) for name in names]
    sets += [
        ("uneven", "demand", ["dna-random-4096"] * 4 +
         ["dna-random-512", "dna-similar-512", "boundary-31", "unequal"] * 7),
        # The first large job delays the tail's ready fork tree. The tiny
        # sibling leaves idle workers before the 64 medium jobs become ready.
        ("late-fork", "late", ["dna-random-4096", "boundary-31"] +
         ["dna-random-512"] * 64),
    ]
    return [{"name": name, "mode": mode, "cases": selected,
             "jobs": [(cases[n]["query"], cases[n]["target"], AlignConfig()) for n in selected],
             "distances": [cases[n]["distance"] for n in selected]}
            for name, mode, selected in sets]


def build(compiler, directory, cc):
    directory.mkdir(parents=True, exist_ok=True)
    source, binary = directory / "probe.c", directory / "probe"
    commands = [[compiler, ROOT / "benchmarks/cpu_batch_probe.bend", "-o", source]]
    command(commands[0])
    source.write_text(instrument(source.read_text(), bang_required=False))
    commands.append([*cc, "-std=c2x", "-O3", "-pthread", source, "-lm", "-o", binary])
    command(commands[1])
    return binary, [[str(arg) for arg in argv] for argv in commands]


def measure(binary, workload, threads, cpus, expected, timeout):
    payload = b"".join(encode_request(*job) for job in workload["jobs"])
    argv = [str(binary), "--threads", str(threads), "--gpu", "off", "--",
            workload["mode"], str(len(workload["jobs"]))]
    original = os.sched_getaffinity(0)
    try:
        os.sched_setaffinity(0, cpus[:threads])
        started = time.monotonic_ns()
        result = subprocess.run(argv, cwd=ROOT, input=payload, capture_output=True, timeout=timeout)
        wall = time.monotonic_ns() - started
    finally:
        os.sched_setaffinity(0, original)
    if result.returncode:
        raise RuntimeError(f"{argv!r} exited {result.returncode}: {result.stderr.decode(errors='replace')}")
    values = decode_batch(result.stdout, len(expected))
    if values != expected or [v.require_distance() for v in values] != workload["distances"]:
        raise RuntimeError(f"Full ordered result mismatch: {workload['name']}, {binary}, {threads} threads")
    metrics = parse_metrics(result.stderr.decode(), device=False)
    if metrics["work_ns"] <= 0:
        raise RuntimeError("Execution timer did not advance")
    return {"work_ns": metrics["work_ns"], "end_to_end_ns": wall,
            "restore_write_ns": metrics["restore_write_ns"],
            "output_sha256": hashlib.sha256(result.stdout).hexdigest(),
            "distance_sum": sum(workload["distances"])}


def write_report(output, document):
    output.mkdir(parents=True, exist_ok=False)
    (output / "results.json").write_text(json.dumps(document, indent=2) + "\n")
    rows = []
    lines = ["# Bend CPU scheduler comparison", "",
             "Every warmup and measured sample matched all ordered result fields from pinned Edlib "
             "and the corpus's independent DP distances. Output SHA-256 checksums also match across releases and thread counts.", "",
             "Fresh processes run sequentially with alternating compiler order, discarded warmups, "
             "and the same first N selected CPUs for N threads. Compilation and Python payload encoding are excluded. "
             "Work times cover execution of prepared plans; end-to-end also includes startup, transport, planning, ordering and writes. "
             "The late-fork control adds a serial lead alignment before a wide tail plan in one outer branch; "
             "the other branch runs a tiny alignment. It is a benchmark shape, not a public API change.", "",
             "Ratios are baseline time / candidate time (>1 means the candidate was faster). "
             "These are workload observations, not portable speedup guarantees or timing assertions.", "",
             "| Case | Threads | Baseline work ms | Candidate work ms | Work ratio | E2E ratio | Candidate pairs/s |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for comparison in document["comparisons"]:
        base, new = comparison["baseline"], comparison["candidate"]
        b, n = base["summary"], new["summary"]
        row = {"case": base["case"], "threads": base["threads"], "batch_size": base["batch_size"],
               "baseline_work_ms": b["work_ns"]["median"] / 1e6,
               "candidate_work_ms": n["work_ns"]["median"] / 1e6,
               "baseline_end_to_end_ms": b["end_to_end_ns"]["median"] / 1e6,
               "candidate_end_to_end_ms": n["end_to_end_ns"]["median"] / 1e6,
               "work_ratio": b["work_ns"]["median"] / n["work_ns"]["median"],
               "end_to_end_ratio": b["end_to_end_ns"]["median"] / n["end_to_end_ns"]["median"],
               "baseline_pairs_per_second": base["batch_size"] * 1e9 / b["work_ns"]["median"],
               "candidate_pairs_per_second": new["batch_size"] * 1e9 / n["work_ns"]["median"],
               "output_sha256": new["samples"][0]["output_sha256"],
               "distance_sum": new["samples"][0]["distance_sum"]}
        rows.append(row)
        lines.append(f"| {row['case']} | {row['threads']} | {row['baseline_work_ms']:.3f} | "
                     f"{row['candidate_work_ms']:.3f} | {row['work_ratio']:.3f} | "
                     f"{row['end_to_end_ratio']:.3f} | {row['candidate_pairs_per_second']:.1f} |")
    with (output / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (output / "REPORT.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path, help="Bend 2.0.36 executable")
    parser.add_argument("--candidate", type=Path, default=ROOT / "build/tools/bend/bin/bend")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--threads", nargs="+", type=int, choices=(1, 2, 4), default=[1, 2, 4])
    parser.add_argument("--cpus", help="Ordered comma-separated logical CPUs; choose physical cores deliberately")
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    started_at = datetime.now(timezone.utc).isoformat()
    cpus = [int(c) for c in args.cpus.split(",")] if args.cpus else sorted(os.sched_getaffinity(0))
    threads = sorted(set([1, *args.threads]))
    if (args.repeats < 1 or args.warmups < 0 or args.timeout < 1 or len(cpus) < max(threads)
            or len(set(cpus)) != len(cpus) or not set(cpus) <= os.sched_getaffinity(0)):
        parser.error("Invalid repeats/warmups/timeout or unavailable/duplicate CPU affinity")
    output = args.output.resolve()
    if output.exists():
        parser.error("Output already exists; choose a fresh directory")
    compilers = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    versions = {name: command([path, "version"]) for name, path in compilers.items()}
    if versions != {"baseline": "bend 2.0.36", "candidate": "bend " + (ROOT / ".bend-version").read_text().strip()}:
        parser.error(f"Unexpected compilers: {versions}")
    cc, cxx = shlex.split(os.environ.get("CC", "clang")), shlex.split(os.environ.get("CXX", "g++"))
    build_root = ROOT / "build/benchmarks/toolchains"
    binaries, builds = {}, {}
    for name, compiler in compilers.items():
        binaries[name], builds[name] = build(compiler, build_root / name, cc)
    edlib = build_root / "edlib"
    source = ROOT / "vendor/edlib/edlib"
    command([*cxx, "-std=c++14", "-O2", "-I", source / "include", ROOT / "tests/edlib_oracle.cpp",
             source / "src/edlib.cpp", "-o", edlib])
    corpus_path = ROOT / "benchmarks/corpus.json"
    cases = workloads(load_corpus(corpus_path))
    comparisons = []
    for workload in cases:
        payload = b"".join(encode_request(*job) for job in workload["jobs"])
        oracle = subprocess.run([str(edlib), "--worker"], input=payload, capture_output=True,
                                check=True, timeout=args.timeout)
        expected = decode_batch(oracle.stdout, len(workload["jobs"]))
        digest = None
        for count in threads:
            samples = {name: [] for name in compilers}
            for repeat in range(args.warmups + args.repeats):
                order = list(compilers) if repeat % 2 == 0 else list(reversed(compilers))
                for name in order:
                    sample = measure(binaries[name], workload, count, cpus, expected, args.timeout)
                    if digest is not None and digest != sample["output_sha256"]:
                        raise RuntimeError("Serialized output changed across compilers/threads")
                    digest = sample["output_sha256"]
                    if repeat >= args.warmups:
                        samples[name].append(sample)
            comparisons.append({name: {"case": workload["name"], "threads": count,
                                      "batch_size": len(expected), "cpus": cpus[:count],
                                      "samples": values, "summary": summarize(values)}
                                for name, values in samples.items()})
            print(f"Verified {workload['name']}, threads={count}", flush=True)
    sources = [*ROOT.glob("*.bend"), *ROOT.glob("src/*.bend"), ROOT / "src/transport.c",
               Path(__file__), ROOT / "benchmarks/cpu_batch_probe.bend", ROOT / "benchmarks/gpu_metrics.bend",
               ROOT / "benchmarks/gpu_metrics.c", ROOT / "benchmarks/gpu_runner.py", ROOT / "transport.py",
               ROOT / "alignment.py", ROOT / "tests/edlib_oracle.cpp", source / "src/edlib.cpp",
               source / "include/edlib.h", ROOT / ".bend-version"]
    cpu = json.loads(command(["lscpu", "-J"]))["lscpu"]
    document = {"schema": 1, "versions": versions, "arguments": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                "started_at_utc": started_at, "finished_at_utc": datetime.now(timezone.utc).isoformat(),
                "cpu_model": next(row["data"] for row in cpu if row["field"] == "Model name:"),
                "platform": platform.platform(), "cpu_topology": command(["lscpu", "-p=CPU,CORE,SOCKET"]),
                "clang": command([*cc, "--version"]), "cxx": command([*cxx, "--version"]),
                "git_commit": command([*git_command(), "rev-parse", "HEAD"]),
                "git_status": command([*git_command(), "status", "--porcelain"]),
                "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sources},
                "corpus_sha256": sha(corpus_path), "edlib_gitlink": command([*git_command(), "ls-tree", "HEAD", "vendor/edlib"]),
                "compiler_sha256": {name: sha(path) for name, path in compilers.items()},
                "binary_sha256": {name: sha(path) for name, path in {**binaries, "edlib": edlib}.items()}, "build_commands": builds,
                "workloads": [{k: v for k, v in w.items() if k != "jobs"} for w in cases], "comparisons": comparisons}
    write_report(output, document)


if __name__ == "__main__":
    main()
