"""Synchronized device evidence for persistent, prepared CUDA workers."""

import json
import re

from benchmarks.gpu_runner import BUILD, ROOT, command, instrument, prerequisites


def build_session_probe(cc=None):
    cc = cc or ["clang-19"]
    source = BUILD / "session.c"
    binary = BUILD / "gpu-session"
    command(["bend", ROOT / "gpu_batch.bend", "-o", source])
    text = source.read_text()
    # The shared hook validates one reachable bang. This entry has three
    # (ordinary single, ordinary batch, prepared batch); preserve that count.
    match = re.search(r"#define BANGS\s+3\b", text)
    if not match:
        raise RuntimeError("Review the persistent worker's reachable bangs")
    text = instrument(text[:match.start()] + "#define BANGS 1" + text[match.end():])
    text = text.replace("#define BANGS 1", "#define BANGS 3", 1)
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
