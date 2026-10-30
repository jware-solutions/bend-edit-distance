"""Batch alignment correctness on CPU and optional GPU execution."""

import subprocess

import pytest

from alignment import AlignConfig
from bend_runtime import runtime_prefix
from benchmarks.gpu_runner import decode_batch, measure
from tests.helpers import assert_valid_path, cpp_edlib_align
from tests.test_batches import mixed_jobs, singles
from transport import encode_request


def session_results(binary, reference, *, gpu, repeats=2):
    import itertools
    from alignment import EqualityPair, Mode, Task, MaxDistance
    from transport import AlignmentWorker
    query = b"A\0\xffN" * 17
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"))
    targets = [b"", b"A", query, query[::-1], bytes(range(256)), b"Z" * 64,
               b"A", query[:31], query[:32], query[:33]]
    bangs = 0
    with AlignmentWorker([binary, *runtime_prefix(threads=4, gpu=gpu), "--worker"]) as w, \
            AlignmentWorker([reference, *runtime_prefix(threads=4), "--worker"]) as ref:
        with w.prepare(query, pairs, timeout=60) as prepared:
            retained = w.retained_bytes
            for mode, task in itertools.product(Mode, Task):
                config = AlignConfig(mode, task, equalities=pairs)
                assert prepared.align_batch(targets, config, timeout=120) == [
                    ref.align(query, target, config) for target in targets]
                bangs += 1
            assert prepared.align_batch([]) == []
            for index in range(repeats):
                config = AlignConfig(threshold=MaxDistance(index % 3), equalities=pairs)
                values = targets[::-1] if index % 2 else targets
                assert prepared.align_batch(values, config, timeout=120) == [
                    ref.align(query, target, config) for target in values]
                bangs += 1
                assert w.retained_bytes == retained
            assert prepared.align(query, timeout=120).edit_distance == 0
            bangs += 1
            # Cross the 1,024-owner wave boundary twice. Distinct distances
            # expose reordered/dropped results as well as incomplete bangs.
            large = [query if i % 3 == 0 else b"Z" + query[1:] for i in range(2051)]
            config = AlignConfig(threshold=MaxDistance(1), equalities=pairs)
            assert prepared.align_batch(large, config, timeout=120) == [
                ref.align(query, target, config) for target in large]
            bangs += 3
        # Scalar prepared NW keeps one word in registers through long target
        # scans; consecutive calls still reset the owned band workspace.
        for length in (1, 7, 31, 32, 33, 63, 64, 65):
            query = (b"A\0\xffN" * 17)[:length]
            values = [b"", query, b"Z" * 4097, bytes(range(256)), query]
            with w.prepare(query, pairs, timeout=60) as word:
                for task in Task:
                    config = AlignConfig(task=task, equalities=pairs)
                    assert word.align_batch(values, config, timeout=120) == [
                        ref.align(query, value, config) for value in values]
                    bangs += 1
                assert word.align(query, timeout=120).edit_distance == 0
                bangs += 1
        # Fixed-length start resolution must complete on the device even when
        # thousands of tied locations survive, including the empty prefix.
        for query, target, pairs in [(b"A", b"C" * 4097, ()),
                (b"A" * 65, b"N" * 4097, (EqualityPair("A", "N"),)),
                (bytes(range(256)), bytes(range(256)) * 17, ())]:
            with w.prepare(query, pairs, timeout=60) as tied:
                for task in (Task.LOC, Task.PATH):
                    config = AlignConfig(Mode.HW, task, equalities=pairs)
                    values = [target, target[:33], target]
                    assert tied.align_batch(values, config, timeout=120) == [
                        ref.align(query, value, config) for value in values]
                    bangs += 1
        assert prepared.released
        assert w.retained_entries == w.retained_bytes == 0
    assert w.process.returncode == 0, w._diagnostics
    return w._diagnostics, bangs


def test_persistent_gpu_entry_cpu_results(gpu_binary, bend_binary):
    session_results(gpu_binary, bend_binary, gpu="off")


@pytest.mark.gpu
def test_successive_prepared_cuda_batches(gpu_session_probe, bend_binary):
    from benchmarks.session_runner import session_metrics
    diagnostics, bangs = session_results(gpu_session_probe, bend_binary, gpu="1GB", repeats=32)
    metrics = session_metrics(diagnostics, bangs)
    # Warm sessions must not retain a new device arena for every batch.
    assert metrics["peak_bytes"] - metrics["baseline_bytes"] < 256 * 1024 * 1024


def long_path_results(binary, reference, oracle, *, gpu):
    import random
    from alignment import EqualityPair, Mode, Task
    from transport import AlignmentWorker
    rng = random.Random(1614)
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    bangs = 0
    with AlignmentWorker([binary, *runtime_prefix(threads=4, gpu=gpu), "--worker"]) as worker, \
            AlignmentWorker([reference, *runtime_prefix(threads=4), "--worker"]) as ref:
        for length in (1024, 4097, 8193):
            query = bytes(rng.choices(b"ACN\0\xff", k=length)) if length != 8193 else (bytes(range(256)) * 33)[:length]
            edited = bytearray(query)
            edited[length // 2] ^= 0x55
            targets = [query, bytes(edited), b"Z" + bytes(edited)]
            if length == 1024:
                targets.append(bytes(rng.choices(b"ACN\0\xff", k=length + 1)))
            with worker.prepare(query, pairs, timeout=120) as prepared:
                for mode in Mode:
                    config = AlignConfig(mode, Task.PATH, equalities=pairs)
                    actual = prepared.align_batch(targets, config, timeout=120)
                    assert actual == [ref.align(query, target, config, timeout=120) for target in targets]
                    for target, result in zip(targets, actual):
                        expected = cpp_edlib_align(query, target, config, binary=oracle, timeout=120)
                        assert (result.status, result.distance, result.end_locations, result.start_locations) == (
                            expected.status, expected.distance, expected.end_locations, expected.start_locations)
                        assert_valid_path(query, target, config, result)
                    bangs += 1
        assert worker.retained_entries == worker.retained_bytes == 0
    assert worker.process.returncode == 0, worker._diagnostics
    return worker._diagnostics, bangs


def test_long_paths_gpu_entry_cpu_results(gpu_binary, bend_binary, cpp_binary):
    long_path_results(gpu_binary, bend_binary, cpp_binary, gpu="off")


@pytest.mark.gpu
def test_long_paths_complete_on_cuda(gpu_session_probe, bend_binary, cpp_binary):
    from benchmarks.session_runner import session_metrics
    diagnostics, bangs = long_path_results(gpu_session_probe, bend_binary, cpp_binary, gpu="1GB")
    session_metrics(diagnostics, bangs)


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
