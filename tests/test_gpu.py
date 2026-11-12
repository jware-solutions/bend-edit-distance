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
        # Prepared NW crosses scalar/banded query boundaries through long
        # targets; consecutive calls still reset the owned band workspace.
        for length in (1, 7, 31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129):
            query = (b"A\0\xffN" * 33)[:length]
            values = [b"", query, b"Z" * 4097, bytes(range(256)), query]
            with w.prepare(query, pairs, timeout=60) as word:
                for task in Task:
                    config = AlignConfig(task=task, equalities=pairs)
                    assert word.align_batch(values, config, timeout=120) == [
                        ref.align(query, value, config) for value in values]
                    bangs += 1
                assert word.align(query, timeout=120).edit_distance == 0
                bangs += 1
        # Successful diagonal retry bounds and ordinary retry fallback must
        # complete across successive device requests with the same owner.
        for length, stride in ((1024, 13), (4096, 43)):
            query = (b"A\0\xffN" * (length // 4))
            changed = bytearray(query)
            for index in range(0, length, stride):
                changed[index] ^= 0x55
            values = [bytes(changed), query, b"Z" * length, bytes(changed)]
            with w.prepare(query, pairs, timeout=60) as retry:
                for task in (Task.DISTANCE, Task.LOC):
                    config = AlignConfig(task=task, equalities=pairs)
                    assert retry.align_batch(values, config, timeout=120) == [
                        ref.align(query, value, config, timeout=120) for value in values]
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
    query = bytes(range(65))
    target = bytes(range(256)) * 4 + bytes(range(17))
    # Both ordinary input orders at a Phase 8 skew boundary. Successful
    # responses must come from the synchronized device dispatch below.
    jobs += [(query, target, AlignConfig()), (target, query, AlignConfig())]
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


@pytest.mark.gpu
def test_direct_equality_masks_in_prepared_cuda_owners(gpu_session_probe, bend_binary):
    from alignment import EqualityPair, Mode
    from transport import AlignmentWorker
    from benchmarks.session_runner import session_metrics
    pairs = ((EqualityPair('A', 'N'), EqualityPair('N', 'C'), EqualityPair('N', 'A')) * 32 +
             tuple(EqualityPair(a, a + 1) for a in range(128, 255)))
    bangs = 0
    with AlignmentWorker([gpu_session_probe, *runtime_prefix(threads=4, gpu='1GB'), '--worker']) as w, \
            AlignmentWorker([bend_binary, *runtime_prefix(threads=4), '--worker']) as ref:
        for length in (31, 33, 129, 4097):
            query = b'A' * length
            targets = [query, b'N' * length, b'C' * length, query[:-1] + b'C', b'\0\xff', query]
            with w.prepare(query, pairs, timeout=120) as prepared:
                charge = w.retained_bytes
                for mode in Mode:
                    config = AlignConfig(mode=mode, equalities=pairs)
                    actual = prepared.align_batch(targets, config, timeout=120)
                    assert actual == [ref.align(query, t, config, timeout=120) for t in targets]
                    assert w.retained_bytes == charge
                    bangs += 1
            assert w.retained_bytes == w.retained_entries == 0
    assert w.process.returncode == 0, w._diagnostics
    session_metrics(w._diagnostics, bangs)  # Requires positive synchronized completion.


@pytest.mark.gpu
def test_each_prepared_cuda_request_has_its_own_completion(gpu_session_probe, cpp_binary):
    from benchmarks.session_runner import RequestEvidence, wave_plan
    from alignment import Mode, Task, MaxDistance, CigarFormat, EqualityPair
    from transport import AlignmentWorker
    import random
    rng = random.Random(10031)
    # This small profile retains the requested 1,024 independent owners;
    # separate production owner-count diagnostics cover budget-limited pools.
    query = bytes(rng.choices(b'ACGT', k=33))
    pairs = (EqualityPair('A', 'N'), EqualityPair('N', 'C'))
    with AlignmentWorker([gpu_session_probe, *runtime_prefix(threads=2, gpu='1GB'), '--worker']) as worker:
        evidence = RequestEvidence(worker)
        prepared = worker.prepare(query, pairs, timeout=120)
        evidence.read(1, 0)
        # Exercise real capability negotiation/rejection and compatible retry.
        target = query[:-1] + b'N'
        value = prepared.align(target, AlignConfig(equalities=pairs), timeout=120)
        evidence.read(6, 0)  # <=64 probes op6 directly, then falls back to op2.
        evidence.read(2, 1)
        assert value == cpp_edlib_align(query, target, AlignConfig(equalities=pairs), binary=cpp_binary)
        worker._owned_supported = {6: False, 7: False}
        charge = worker.retained_bytes
        for count in (0, 1, 2, 8, 32, 128, 512, 1023, 1024, 1025, 2051):
            targets = [bytes(rng.choices(b'ACGTN\0\xff', k=i % 35)) for i in range(count)]
            config = AlignConfig(threshold=MaxDistance(1), equalities=pairs)
            actual = prepared.align_batch(targets, config, timeout=120)
            evidence.read(5, len(wave_plan(count, 1024)))
            for target, result in zip(targets, actual):
                assert result == cpp_edlib_align(query, target, config, binary=cpp_binary)
            assert worker.retained_bytes == charge
        # Successive task/mode/format changes retain ordered tied endpoints and
        # validate complete paths against independent public Edlib.
        targets = [query, query[:-1] + b'Z', b'Z' + query + b'ZZ' + query, b'']
        for mode in Mode:
            for task in Task:
                for format in CigarFormat:
                    config = AlignConfig(mode, task, equalities=pairs, cigar_format=format)
                    actual = prepared.align_batch(targets, config, timeout=120)
                    evidence.read(5, 1)
                    for target, result in zip(targets, actual):
                        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
                        assert (result.status, result.distance, result.end_locations, result.start_locations) == (
                            expected.status, expected.distance, expected.end_locations, expected.start_locations)
                        assert_valid_path(query, target, config, result)
        jobs = [(b'A', b'A', AlignConfig()), (b'AC', b'CA', AlignConfig()),
                (b'\0\xff', b'\xff', AlignConfig())]
        assert worker.align_batch(jobs, timeout=120) == [
            cpp_edlib_align(*job, binary=cpp_binary) for job in jobs]
        evidence.read(4, 1)  # Nested BED1 input frames form one ordinary bang.
        prepared.release()
        evidence.read(3, 0)
        assert worker.retained_bytes == worker.retained_entries == 0
        assert not prepared.release()


@pytest.mark.gpu
def test_cuda_padding_capacity_and_reprepare_boundaries(gpu_session_probe, cpp_binary):
    from benchmarks.session_runner import RequestEvidence
    from transport import AlignmentWorker
    from alignment import MaxDistance
    with AlignmentWorker([gpu_session_probe, *runtime_prefix(threads=1, gpu='1GB'), '--worker']) as worker:
        evidence = RequestEvidence(worker)
        worker._owned_supported = {6: False, 7: False}
        lengths = [*range(65, 97), 127, 128, 129, 4095, 4096, 4097, 65535, 65536, 65537]
        for length in lengths:
            query = (bytes(range(256)) * ((length + 255) // 256))[:length]
            prepared = worker.prepare(query, timeout=120)
            evidence.read(1, 0)
            # One target is independent of retained-owner count. The long
            # controls reject by length; high-distance long searches are bounded
            # separately and cannot be inferred from these eligibility checks.
            # Three real mismatches fail the zero/one certificate. Missing
            # byte 255 forces the mask/padding route for every short final-word
            # length, rather than validating padding with a certified hit.
            config = AlignConfig() if length < 4095 else AlignConfig(threshold=MaxDistance(0))
            target = query[:-3] + b'\xff' * 3 if length < 4095 else b'Z'
            values = prepared.align_batch([target], config, timeout=120)
            evidence.read(5, 1)
            assert values == [cpp_edlib_align(query, target, config, binary=cpp_binary)]
            prepared.release()
            evidence.read(3, 0)
            assert worker.retained_bytes == worker.retained_entries == 0
        maximum = worker.prepare(b'A' * 1048576, timeout=120)
        evidence.read(1, 0)
        assert worker.retained_entries == 1
        maximum.release()
        evidence.read(3, 0)
        assert worker.retained_bytes == 0


@pytest.mark.gpu
def test_budget_limited_cuda_pool_crosses_actual_owner_boundary(gpu_session_probe, cpp_binary):
    from transport import AlignmentWorker
    from benchmarks.session_runner import RequestEvidence, wave_plan
    from alignment import MaxDistance
    # All 256 rows, 2,049 logical U32 words rounded to stride 4,096. The
    # selected pool accounting retains four independent owners, not 1,024.
    query = (bytes(range(256)) * 257)[:65537]
    with AlignmentWorker([gpu_session_probe, *runtime_prefix(threads=4, gpu='1GB'), '--worker']) as worker:
        worker._owned_supported = {6: False, 7: False}
        evidence = RequestEvidence(worker)
        prepared = worker.prepare(query, timeout=120)
        evidence.read(1, 0)
        assert worker.retained_bytes == 19157024
        for count in (3, 4, 5, 9):
            targets = [bytes([i]) * (i + 1) for i in range(count)]
            config = AlignConfig(threshold=MaxDistance(0))
            results = prepared.align_batch(targets, config, timeout=120)
            evidence.read(5, len(wave_plan(count, 4)))
            assert results == [cpp_edlib_align(query, target, config, binary=cpp_binary) for target in targets]
        prepared.release()
        evidence.read(3, 0)
        assert worker.retained_bytes == worker.retained_entries == 0
