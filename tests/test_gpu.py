"""CPU controls always run; genuine-device tests opt in and fail on fallback."""

import json
import subprocess

import pytest

from alignment import AlignConfig
from benchmarks.gpu_runner import (HOOK, PREFIX, crossover, decode_batch, instrument,
                                   measure, parse_metrics, prerequisites, require_gpu_build)
from tests.test_batches import mixed_jobs, singles
from transport import encode_request


def test_cuda_discovery_supports_system_toolkit_and_respects_override(monkeypatch):
    from pathlib import Path
    monkeypatch.delenv("CUDA_HOME", raising=False)
    monkeypatch.setattr(Path, "is_file", lambda path: str(path) in
                        ("/usr/include/cuda.h", "/usr/include/nvrtc.h"))
    monkeypatch.setattr("benchmarks.gpu_runner.command", lambda argv: "Ubuntu clang version 19.1.7")
    cuda, _, problems = prerequisites(["clang"])
    assert cuda == Path("/usr") and problems == []
    monkeypatch.setenv("CUDA_HOME", "/missing-toolkit")
    cuda, _, problems = prerequisites(["clang"])
    assert cuda == Path("/missing-toolkit") and any("missing" in p for p in problems)


def test_missing_compiler_is_a_reportable_prerequisite(monkeypatch):
    def missing(argv):
        raise FileNotFoundError("clang")
    monkeypatch.setattr("benchmarks.gpu_runner.command", missing)
    _, version, problems = prerequisites(["clang"])
    assert version == "unavailable"
    assert any("Cannot run C compiler" in p for p in problems)


def metrics(**patch):
    value = {"schema": 1, "backend": "cuda", "device_passes": 2,
             "device_pass_ns": 80, "work_ns": 100, "restore_write_ns": 20,
             "prefetch_in_ns": 10, "prefetch_out_ns": 10,
             "prefetch_in_requested_bytes": 256, "prefetch_out_requested_bytes": 512,
             "managed_heap_bytes": 2**30, "device_used_peak_sample_bytes": 200,
             "device_used_baseline_bytes": 100}
    value.update(patch)
    return PREFIX + json.dumps(value)


@pytest.mark.parametrize("patch", [
    {"backend": "cpu"}, {"device_passes": 0}, {"device_pass_ns": 0},
    {"device_passes": True}, {"work_ns": -1}, {"schema": 2},
    {"device_used_peak_sample_bytes": None}, {"managed_heap_bytes": 0},
    {"device_used_peak_sample_bytes": 99},
    {"device_pass_ns": 101},
])
def test_rejects_fallback_or_invalid_device_evidence(patch):
    with pytest.raises(RuntimeError):
        parse_metrics(metrics(**patch), device=True)


def test_requires_one_positive_device_record():
    assert parse_metrics(metrics(), device=True)["device_passes"] == 2
    for text in ("", metrics() + "\n" + metrics(), "bend: GPU program compiled", PREFIX + "oops", PREFIX + "[]"):
        with pytest.raises(RuntimeError):
            parse_metrics(text, device=True)
    with pytest.raises(RuntimeError):
        parse_metrics(metrics(), device=False)


def test_instrumentation_counts_only_completed_device_passes():
    source = "#define BANGS 1\nstatic void cube_run(u64* H, bool gpu) {\n    if (gpu) {\n      gpu_pass(f);\n    } else {\n      cpu_pass(f);\n    }\n}"
    actual = instrument(source)
    assert actual.index("gpu_pass(f);") < actual.index("bend_device_passes += 1;") < actual.index("cpu_pass(f);")
    assert HOOK in actual
    for bad in (source.replace("BANGS 1", "BANGS 0"), source.replace("gpu_pass(f);", "changed();"), source + source):
        with pytest.raises(RuntimeError):
            instrument(bad)


def test_crossover_reports_only_measured_wins():
    records = [{"case": "example", "backend": backend, "transfer": "demand", "batch_size": n,
                "summary": {"end_to_end_ns": {"median": value}}}
               for n, cpu, gpu in [(1, 10, 20), (3, 30, 29), (7, 50, 55)]
               for backend, value in [("cpu", cpu), ("cuda", gpu)]]
    result = crossover(records, ["example"], [1, 3, 7])["example"]
    assert result["first_measured_gpu_win"] == 3
    assert result["gpu_winning_batch_sizes"] == [3]
    records[3]["summary"]["end_to_end_ns"]["median"] = 31
    assert crossover(records, ["example"], [1, 3, 7])["example"]["first_measured_gpu_win"] is None


def test_crossover_compares_edlib_without_treating_it_as_cpu():
    records = [{"case": "example", "backend": backend, "transfer": "demand", "batch_size": 16,
                "summary": {"end_to_end_ns": {"median": value}}}
               for backend, value in [("cpu", 100), ("cuda", 50), ("edlib", 10)]]
    result = crossover(records, ["example"], [16])["example"]
    assert result["first_measured_gpu_win"] == 16
    assert result["first_measured_gpu_win_vs_edlib"] is None


@pytest.mark.parametrize("count", [0, 1, 3, 17])
def test_gpu_entry_cpu_fallback_preserves_order(gpu_binary, bend_binary, count):
    jobs = [(bytes([i]) * (i % 5), b"Z" * (i % 7), AlignConfig()) for i in range(count)]
    payload = b"".join(encode_request(*job) for job in jobs)
    for threads in (1, 4):
        result = subprocess.run([str(gpu_binary), "--gpu", "off", "--threads", str(threads),
                                 "--", str(count)], input=payload, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        assert decode_batch(result.stdout, count) == singles(jobs, bend_binary)


@pytest.mark.parametrize("args,payload", [([], b""), (["bad"], b""), (["-1"], b""),
                                            (["1"], b""), (["2"], encode_request(b"A", b"C", AlignConfig()))])
def test_gpu_batch_rejects_bad_count_and_missing_requests(gpu_binary, args, payload):
    result = subprocess.run([str(gpu_binary), "--gpu", "off", "--", *args],
                            input=payload, capture_output=True, timeout=30)
    assert result.returncode != 0
    assert result.stdout == b""
    assert result.stderr


def test_cpu_probe_full_result_equivalence_and_no_device_claim(gpu_cpu_probe, bend_binary):
    jobs = mixed_jobs()
    values, evidence = measure(gpu_cpu_probe, jobs, device=False, threads=4)
    assert values == singles(jobs, bend_binary)
    assert evidence["backend"] == "cpu" and evidence["device_passes"] == 0
    assert evidence["device_used_peak_sample_bytes"] is None
    with pytest.raises(RuntimeError, match="CPU fallback"):
        parse_metrics(PREFIX + json.dumps(evidence), device=True)
    with pytest.raises(RuntimeError, match="exited"):
        measure(gpu_cpu_probe, jobs, device=True)
    # The pinned runtime can exit zero from --gpu-build without a device.
    # An actual, freshly generated device sidecar is independently required.
    with pytest.raises(RuntimeError, match="no device program"):
        require_gpu_build(gpu_cpu_probe)


def test_cpu_benchmark_control_matches_public_batch_api(cpu_batch_control, bend_binary):
    jobs = mixed_jobs()
    for threads in (1, 4):
        values, evidence = measure(cpu_batch_control, jobs, device=False, threads=threads)
        assert values == singles(jobs, bend_binary)
        assert evidence["device_passes"] == 0 and evidence["backend"] == "cpu"


@pytest.mark.gpu
def test_gpu_production_device_build(gpu_binary):
    sidecar = require_gpu_build(gpu_binary)
    assert sidecar["bytes"] > 8
    result = subprocess.run([str(gpu_binary), "--gpu", "on", "--", "1"],
                            input=encode_request(b"kitten", b"sitting", AlignConfig()),
                            capture_output=True, timeout=180)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert decode_batch(result.stdout, 1)[0].require_distance() == 3


@pytest.mark.gpu
def test_genuine_device_matches_cpu_all_fields(gpu_device_probe, bend_binary):
    jobs = mixed_jobs()
    expected = singles(jobs, bend_binary)
    for threads in (1, 4):
        for prefetch in (False, True):
            values, evidence = measure(gpu_device_probe, jobs, device=True,
                                       prefetch=prefetch, threads=threads)
            assert values == expected
            assert evidence["device_passes"] > 0
            assert evidence["managed_heap_bytes"] > 0
            if prefetch:
                assert evidence["prefetch_in_ns"] > 0 and evidence["prefetch_out_ns"] > 0


@pytest.mark.gpu
def test_long_distance_inputs_do_not_exhaust_device_length_stack(gpu_device_probe, bend_binary):
    from benchmarks.runner import ROOT, load_corpus
    case = next(c for c in load_corpus(ROOT / "benchmarks/corpus.json")["cases"]
                if c["name"] == "dna-random-4096")
    jobs = [(case["query"], case["target"], AlignConfig()),
            ("", case["target"], AlignConfig()),
            (case["query"], "", AlignConfig()),
            (case["query"], "ACG", AlignConfig())]
    expected = singles(jobs, bend_binary)
    for prefetch in (False, True):
        values, evidence = measure(gpu_device_probe, jobs, device=True,
                                   prefetch=prefetch, threads=4)
        assert values == expected
        assert values[0].require_distance() == case["distance"]
        assert evidence["device_passes"] > 0
