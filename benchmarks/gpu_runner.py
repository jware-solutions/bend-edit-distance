"""Strict CUDA validation and batch crossover measurement; no GPU fallback claims."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import statistics
import subprocess
import time

from alignment import AlignConfig
from benchmarks.runner import command, load_corpus, summarize
from transport import LENGTH, decode_response, encode_request

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/gpu"
PREFIX = "BEND_GPU_METRICS "

# These hooks observe ONLY successfully synchronized device scheduler passes.
# Fail closed when the pinned runtime's structure changes. The pure library
# and the production executable are never patched.
HOOK = """
static uint64_t bend_device_passes, bend_device_ns;
static uint64_t bend_device_used_peak, bend_device_used_baseline;
static uint64_t bend_device_now(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
  return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}
static void bend_device_memory(void) {
#if BEND_CUDA
  size_t available, total;
  if (cuMemGetInfo(&available, &total) != CUDA_SUCCESS) {
    fprintf(stderr, "Cannot measure device memory\\n"); exit(3);
  }
  uint64_t used = total - available;
  if (!bend_device_used_baseline) bend_device_used_baseline = used;
  if (used > bend_device_used_peak) bend_device_used_peak = used;
#endif
}
"""
PASS = """bend_device_memory();
      uint64_t bend_pass_started = bend_device_now();
      gpu_pass(f);
      bend_device_ns += bend_device_now() - bend_pass_started;
      bend_device_passes += 1;
      bend_device_memory();"""


def instrument(source, *, bang_required=True):
    anchor = "static void cube_run(u64* H, bool gpu) {"
    if source.count(anchor) != 1 or source.count("      gpu_pass(f);") != 1:
        raise RuntimeError("Pinned Bend runtime changed; review GPU instrumentation")
    if not re.search(r"#define BANGS\s+" + ("1" if bang_required else "0") + r"\b", source):
        raise RuntimeError("Probe has an unexpected reachable-bang setting")
    return source.replace(anchor, HOOK + "\n" + anchor).replace("      gpu_pass(f);", "      " + PASS)


def prerequisites(cc):
    problems = []
    cuda = Path(os.environ.get("CUDA_HOME", "/usr/local/cuda"))
    if not (cuda / "include/cuda.h").is_file() or not (cuda / "include/nvrtc.h").is_file():
        problems.append(f"CUDA headers/NVRTC missing at {cuda}")
    version = command([*cc, "--version"])
    match = re.search(r"clang version (\d+)", version)
    if not match or int(match[1]) < 19:
        problems.append("GPU build requires Clang 19 or newer")
    return cuda, version.splitlines()[0], problems


def build_probe(*, cuda_enabled=False, cpu_control=False, cc=None):
    cc = cc or shlex.split(os.environ.get("CC", "clang"))
    version = command(["bend", "version"])
    if version != "bend " + (ROOT / ".bend-version").read_text().strip():
        raise RuntimeError(f"Unexpected Bend compiler: {version}")
    BUILD.mkdir(parents=True, exist_ok=True)
    if cpu_control and cuda_enabled:
        raise ValueError("CPU control must be built without CUDA")
    entry = "cpu_batch_probe" if cpu_control else "gpu_probe"
    source = BUILD / (entry + ".c")
    binary = BUILD / ("cpu-control" if cpu_control else "gpu-probe" if cuda_enabled else "gpu-probe-cpu")
    command(["bend", ROOT / f"benchmarks/{entry}.bend", "-o", source])
    source.write_text(instrument(source.read_text(), bang_required=not cpu_control), encoding="utf-8")
    argv = [*cc, "-std=c2x", "-O3", "-pthread", source, "-lm", "-o", binary]
    if cuda_enabled:
        cuda, _, problems = prerequisites(cc)
        if problems:
            raise RuntimeError("; ".join(problems))
        argv += ["-DBEND_CUDA=1", "-I", cuda / "include", "-L", cuda / "lib64",
                 f"-Wl,-rpath,{cuda / 'lib64'}", "-lcuda", "-lnvrtc"]
    command(argv)
    return binary


def require_gpu_build(binary):
    sidecar = Path(str(binary) + ".gpu")
    sidecar.unlink(missing_ok=True)  # No stale artifact may satisfy this test.
    command([binary, "--gpu-build"], timeout=300)
    if not sidecar.is_file() or sidecar.stat().st_size <= 8:
        raise RuntimeError("--gpu-build produced no device program (CPU-only build or unusable device)")
    return {"path": str(sidecar), "bytes": sidecar.stat().st_size,
            "sha256": hashlib.sha256(sidecar.read_bytes()).hexdigest()}


def decode_batch(output, count):
    values = []
    while output:
        if len(output) < LENGTH.size:
            raise RuntimeError("Truncated batch response length")
        size = LENGTH.unpack_from(output)[0]
        if len(output) < LENGTH.size + size:
            raise RuntimeError("Truncated batch response")
        values.append(decode_response(output[LENGTH.size:LENGTH.size + size]))
        output = output[LENGTH.size + size:]
    if len(values) != count:
        raise RuntimeError(f"Expected {count} results, received {len(values)}")
    return values


def parse_metrics(stderr, *, device):
    lines = [line[len(PREFIX):] for line in stderr.splitlines() if line.startswith(PREFIX)]
    if len(lines) != 1:
        raise RuntimeError(f"Missing or duplicate device evidence: {stderr}")
    try:
        metrics = json.loads(lines[0])
    except ValueError as error:
        raise RuntimeError("Malformed GPU metrics JSON") from error
    if not isinstance(metrics, dict):
        raise RuntimeError("Malformed GPU metrics object")
    integers = ("device_passes", "device_pass_ns", "work_ns", "restore_write_ns",
                "prefetch_in_ns", "prefetch_out_ns", "prefetch_in_requested_bytes",
                "prefetch_out_requested_bytes", "managed_heap_bytes")
    if metrics.get("schema") != 1 or any(type(metrics.get(k)) is not int or metrics[k] < 0 for k in integers):
        raise RuntimeError("Malformed GPU metrics")
    if device:
        if metrics.get("backend") != "cuda" or metrics["device_passes"] < 1 or metrics["device_pass_ns"] < 1:
            raise RuntimeError("CPU fallback is not device validation")
        if metrics["device_pass_ns"] > metrics["work_ns"]:
            raise RuntimeError("Device passes exceed the measured execution interval")
        for key in ("device_used_peak_sample_bytes", "device_used_baseline_bytes"):
            if type(metrics.get(key)) is not int or metrics[key] < 0:
                raise RuntimeError("Missing device VRAM measurement")
        if metrics["managed_heap_bytes"] <= 0 or metrics["device_used_peak_sample_bytes"] < metrics["device_used_baseline_bytes"]:
            raise RuntimeError("Invalid device memory measurement")
    else:
        if metrics.get("backend") != "cpu" or metrics["device_passes"] != 0 or metrics["device_pass_ns"] != 0:
            raise RuntimeError("CPU control unexpectedly executed on a device")
        if metrics.get("device_used_peak_sample_bytes") is not None or metrics.get("device_used_baseline_bytes") is not None or metrics["managed_heap_bytes"] != 0:
            raise RuntimeError("CPU control must not report GPU memory")
    return metrics


def measure(binary, jobs, *, device, threads=1, heap="1GB", prefetch=False, timeout=180):
    payload = b"".join(encode_request(*job) for job in jobs)
    argv = [str(binary), "--threads", str(threads), "--gpu", heap if device else "off",
            "--", "prefetch" if prefetch else "demand", str(len(jobs))]
    started = time.monotonic_ns()
    result = subprocess.run(argv, cwd=ROOT, input=payload, capture_output=True, timeout=timeout)
    ended = time.monotonic_ns()
    if result.returncode:
        raise RuntimeError(f"GPU probe exited {result.returncode}: {result.stderr.decode(errors='replace')}")
    metrics = parse_metrics(result.stderr.decode(errors="replace"), device=device)
    metrics["end_to_end_ns"] = ended - started
    return decode_batch(result.stdout, len(jobs)), metrics


def crossover(records, cases, sizes):
    result = {}
    for case in cases:
        times = {(r["backend"], r["batch_size"]): r["summary"]["end_to_end_ns"]["median"]
                 for r in records if r["case"] == case and r["transfer"] == "demand"}
        wins = [n for n in sorted(sizes) if times[("cuda", n)] < times[("cpu", n)]]
        result[case] = {"first_measured_gpu_win": wins[0] if wins else None,
                        "gpu_winning_batch_sizes": wins,
                        "tested_batch_sizes": sorted(sizes)}
    return result


def report(document):
    lines = ["# GPU batch measurements", "", "Every CUDA sample passed forced-device execution, completed-dispatch evidence, and full ordered CPU/GPU result equality.", "",
             "Times are median fresh-process samples with interleaved CPU/GPU order. End-to-end includes process/device initialization, input framing, host planning, execution, ordering and response framing. Payload encoding in Python and compilation are excluded. Warm-ups are discarded.", "",
             "`device_pass_ns` is synchronized scheduler wall time, including implicit migration and launch overhead; it is not pure kernel time. The prefetch experiment requests migration of scheduler metadata, allocated arena pages (including freed pages), and occupied allocator-bank entries before and after execution. The requested byte counts are recorded; they are not measured PCIe traffic. This is a controlled transfer cost, not the implicit migration cost of the demand run. Do not subtract separate runs to estimate transfer time.", "",
             "VRAM is device-wide used memory sampled before/after scheduler passes and prefetch, including the baseline and other processes. It is an observed lower bound on peak residency, not exact per-process peak VRAM. Use an otherwise idle GPU. Managed heap bytes are reserved address space, not resident VRAM.", "",
             "| Case | Batch | Backend | Transfer | End-to-end ms | Work ms | Prefetch in/out ms | Observed used VRAM MiB |",
             "| --- | ---: | --- | --- | ---: | ---: | ---: | ---: |"]
    for r in document["records"]:
        s = r["summary"]
        peak = statistics.median(x["device_used_peak_sample_bytes"] for x in r["samples"]) if r["backend"] == "cuda" else None
        transfers = f"{s['prefetch_in_ns']['median']/1e6:.3f}/{s['prefetch_out_ns']['median']/1e6:.3f}" if peak is not None else "—"
        memory = f"{peak/2**20:.1f}" if peak is not None else "—"
        lines.append(f"| {r['case']} | {r['batch_size']} | {r['backend']} | {r['transfer']} | "
                     f"{s['end_to_end_ns']['median']/1e6:.3f} | {s['work_ns']['median']/1e6:.3f} | {transfers} | {memory} |")
    lines += ["", "Crossover uses demand-mode end-to-end medians against a separate CPU-only executable of the same prepared Batch plan and result restoration, preserving Bend's CPU scheduler optimizations. The CPU thread count is recorded. It is workload/machine specific; a first measured win does not imply all larger batches win.", ""]
    for name, value in document["break_even"].items():
        first = value["first_measured_gpu_win"]
        lines.append(f"- {name}: " + (f"first measured GPU win at batch {first}; winning sizes {value['gpu_winning_batch_sizes']}." if first else "no GPU win in the tested range."))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BUILD / "results")
    parser.add_argument("--corpus", type=Path, default=ROOT / "benchmarks/corpus.json")
    parser.add_argument("--case", action="append", dest="cases")
    parser.add_argument("--batch-sizes", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64, 128, 256, 512])
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--heap", default="1GB", help="Forced device heap cap, e.g. 1GB or 512MB")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--check-build", action="store_true", help="Build the device program and verify one genuine execution")
    args = parser.parse_args(argv)
    if platform.system() != "Linux":
        parser.error("Run this CUDA harness in Linux, or use run_gpu_benchmarks.py to forward Windows to WSL")
    if args.repeats < 1 or args.warmups < 0 or not 1 <= args.threads <= 128 or args.timeout <= 0 or any(n < 1 for n in args.batch_sizes):
        parser.error("Invalid repeat, warmup, thread, timeout or batch count")
    if not re.fullmatch(r"[1-9][0-9]*(?:MB|GB)", args.heap):
        parser.error("--heap must be a positive integer followed by MB or GB")
    corpus = load_corpus(args.corpus)
    cases = [c for c in corpus["cases"] if not args.cases or c["name"] in args.cases]
    if not cases or args.cases and set(args.cases) - {c["name"] for c in cases}:
        parser.error("Unknown or empty case selection")
    args.output.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    cc = shlex.split(os.environ.get("CC", "clang"))
    cuda, cc_version, problems = prerequisites(cc)
    document = {"schema": 1, "status": "unvalidated", "environment": {
        "platform": platform.platform(), "compiler": cc_version, "bend": command(["bend", "version"]),
        "cuda_home": str(cuda), "threads": args.threads, "heap": args.heap,
        "corpus_sha256": hashlib.sha256(args.corpus.read_bytes()).hexdigest()},
        "options": {"repeats": args.repeats, "warmups": args.warmups}, "records": [], "break_even": {}}
    document["environment"]["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    document["environment"]["sources_sha256"] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(
            list(ROOT.glob("*.bend")) + list((ROOT / "src").rglob("*.bend")) +
            list((ROOT / "benchmarks").glob("gpu_*")) + [
                ROOT / "src/transport.c", ROOT / "benchmarks/cpu_batch_probe.bend",
                ROOT / "benchmarks/runner.py", ROOT / "run_gpu_benchmarks.py",
                ROOT / "alignment.py", ROOT / "transport.py", ROOT / ".bend-version",
            ])}
    cpuinfo = Path("/proc/cpuinfo").read_text()
    document["environment"]["cpu_model"] = next((line.split(":", 1)[1].strip() for line in cpuinfo.splitlines() if line.startswith("model name")), platform.machine())
    try:
        document["environment"]["nvidia_smi"] = command(["nvidia-smi", "--query-gpu=name,uuid,driver_version,memory.total", "--format=csv,noheader"], timeout=30)
    except (RuntimeError, OSError, subprocess.SubprocessError):
        document["environment"]["nvidia_smi"] = None
    try:
        if problems:
            raise RuntimeError("; ".join(problems))
        print("Building GPU batch CLI and instrumented probe...", flush=True)
        command(["bend", ROOT / "gpu_batch.bend", "-o", BUILD / "gpu-batch"], timeout=300)
        document["production_device_program"] = require_gpu_build(BUILD / "gpu-batch")
        binary = build_probe(cuda_enabled=True, cc=cc)
        cpu_binary = build_probe(cpu_control=True, cc=cc)
        document["probe_device_program"] = require_gpu_build(binary)
        # One nonempty call must execute before a build-only run can pass.
        jobs = [(b"kitten", b"sitting", AlignConfig())]
        cpu, _ = measure(cpu_binary, jobs, device=False, threads=args.threads, timeout=args.timeout)
        gpu, evidence = measure(binary, jobs, device=True, threads=args.threads, heap=args.heap, timeout=args.timeout)
        if gpu != cpu or gpu[0].require_distance() != 3:
            raise RuntimeError("Device smoke result differs from CPU/known distance")
        document["device_smoke"] = evidence
        if not args.check_build:
            sizes = sorted(set(args.batch_sizes))
            for case in cases:
                for count in sizes:
                    jobs = [(case["query"], case["target"], AlignConfig())] * count
                    samples = {"cpu": [], "cuda": [], "prefetch": []}
                    for repeat in range(args.warmups + args.repeats):
                        pair = {}
                        for device in ([False, True] if repeat % 2 == 0 else [True, False]):
                            backend = "cuda" if device else "cpu"
                            values, metrics = measure(binary if device else cpu_binary, jobs, device=device, threads=args.threads, heap=args.heap, timeout=args.timeout)
                            if any(v.require_distance() != case["distance"] for v in values):
                                raise RuntimeError(f"Corpus distance mismatch: {case['name']}")
                            pair[backend] = values
                            if repeat >= args.warmups: samples[backend].append(metrics)
                        if pair["cpu"] != pair["cuda"]:
                            raise RuntimeError(f"Full result mismatch: {case['name']} batch {count}")
                        values, metrics = measure(binary, jobs, device=True, prefetch=True, threads=args.threads, heap=args.heap, timeout=args.timeout)
                        if values != pair["cpu"]:
                            raise RuntimeError("Prefetch result mismatch")
                        if repeat >= args.warmups: samples["prefetch"].append(metrics)
                    for kind, values in samples.items():
                        document["records"].append({"case": case["name"], "batch_size": count,
                            "backend": "cpu" if kind == "cpu" else "cuda",
                            "transfer": "prefetch" if kind == "prefetch" else "demand",
                            "samples": values, "summary": summarize(values)})
                    print(f"Validated {case['name']} batch {count}", flush=True)
            document["break_even"] = crossover(document["records"], [c["name"] for c in cases], sizes)
        document["status"] = "device_validated"
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        document["status"] = "failed"
        document["reason"] = str(error)
        raise
    finally:
        (args.output / "results.json").write_text(json.dumps(document, indent=2) + "\n")
        text = report(document) if document["status"] == "device_validated" else "# GPU validation failed\n\n" + document.get("reason", "Validation incomplete") + "\n\nNo GPU equivalence, transfer, VRAM or crossover claim is made.\n"
        (args.output / "REPORT.md").write_text(text, encoding="utf-8")
    return 0
