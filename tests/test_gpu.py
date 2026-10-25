"""Batch alignment correctness on CPU and optional GPU execution."""

import subprocess

import pytest

from alignment import AlignConfig
from bend_runtime import runtime_prefix
from benchmarks.gpu_runner import decode_batch, measure
from tests.helpers import assert_valid_path, cpp_edlib_align
from tests.test_batches import mixed_jobs, singles
from transport import encode_request


def expected_results(jobs, bend_binary, cpp_binary):
    results = singles(jobs, bend_binary)
    for (query, target, config), result in zip(jobs, results):
        oracle = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert (result.status, result.distance, result.end_locations, result.start_locations) == (
            oracle.status, oracle.distance, oracle.end_locations, oracle.start_locations)
        assert_valid_path(query, target, config, result)
    return results


@pytest.mark.parametrize("count", [0, 1, 3, 17])
def test_gpu_entry_cpu_results(gpu_binary, bend_binary, cpp_binary, count):
    jobs = [(bytes([i]) * (i % 5), b"Z" * (i % 7), AlignConfig()) for i in range(count)]
    expected = expected_results(jobs, bend_binary, cpp_binary)
    payload = b"".join(encode_request(*job) for job in jobs)
    for threads in (1, 4):
        result = subprocess.run([str(gpu_binary), *runtime_prefix(threads=threads, gpu="off"), str(count)],
                                input=payload, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        assert decode_batch(result.stdout, count) == expected


@pytest.mark.gpu
def test_gpu_matches_edlib(gpu_device_probe, bend_binary, cpp_binary):
    jobs = mixed_jobs()
    expected = expected_results(jobs, bend_binary, cpp_binary)
    for threads in (1, 4):
        for prefetch in (False, True):
            values, _ = measure(gpu_device_probe, jobs, device=True,
                                prefetch=prefetch, threads=threads)
            assert values == expected


@pytest.mark.gpu
def test_long_gpu_alignments_match_edlib(gpu_device_probe, bend_binary, cpp_binary):
    from benchmarks.runner import ROOT, load_corpus
    case = next(c for c in load_corpus(ROOT / "benchmarks/corpus.json")["cases"]
                if c["name"] == "dna-random-4096")
    jobs = [(case["query"], case["target"], AlignConfig()),
            ("", case["target"], AlignConfig()),
            (case["query"], "", AlignConfig()),
            (case["query"], "ACG", AlignConfig())]
    expected = expected_results(jobs, bend_binary, cpp_binary)
    for prefetch in (False, True):
        values, _ = measure(gpu_device_probe, jobs, device=True,
                            prefetch=prefetch, threads=4)
        assert values == expected
