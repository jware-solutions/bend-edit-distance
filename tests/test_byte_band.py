"""Packed target traversal preserves band state, counters and prepared semantics."""

import random
import subprocess
from pathlib import Path

import pytest

from alignment import AlignConfig, MaxDistance, Status
from benchmarks.gpu_runner import decode_batch
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, cpp_edlib_align, execute
from tests.test_cpu_pools import worker
from tests.test_prepared_bytes import PAIRS, packed_probe
from tests.test_small_paths import distance_dp
from transport import encode_request


@pytest.fixture(scope="module")
def band_probe(bend_tool):
    binary = ROOT / "build/byte-band-probe"
    execute([bend_tool, ROOT / "tests/byte_band_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_packed_band_matches_every_block_and_counter(band_probe, cpp_binary, threads):
    rng = random.Random(651)
    lengths = (*range(129, 161), 191, 192, 193, 255, 256, 257,
               511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097)
    for length in lengths:
        query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
        targets = [b"", query, query[::-1], bytes(range(256)), b"Z" * (length + 1)]
        if length in (129, 160, 257, 1025, 4097):
            targets += [(b"\0\x80\xff" * 3)[:tail] for tail in range(1, 8)]
        for target in targets:
            config = AlignConfig(equalities=PAIRS)
            optimum = (distance_dp(query, target, PAIRS) if max(length, len(target)) <= 300 else
                       cpp_edlib_align(query, target, config, binary=cpp_binary).edit_distance)
            for maximum in (None, max(0, optimum - 1), optimum, optimum + 1):
                options = config if maximum is None else AlignConfig(threshold=MaxDistance(maximum), equalities=PAIRS)
                done = subprocess.run([band_probe, *runtime_prefix(threads=threads)],
                    input=encode_request(query, target, options), capture_output=True, check=True, timeout=60)
                values = [r.edit_distance for r in decode_batch(done.stdout, 9)]
                assert values[:4] == values[4:8], (length, len(target), maximum, values)
                assert values[8] == 1, (length, len(target), maximum)
                assert values[0] == (optimum if maximum is None or optimum <= maximum else -1)
                assert not done.stderr


@pytest.mark.parametrize("length", [1024, 4096, 4097, 16384])
def test_packed_retry_witness_preserves_string_kernel_state(band_probe, length):
    rng = random.Random(length)
    query = bytes(rng.choices(b"ACGT", k=length))
    for edits in (8, 31, 32, 33, 63, 64, 65, 80, 200, length // 2):
        changed = bytearray(query)
        for index in rng.sample(range(length), edits):
            changed[index] ^= 0x55
        done = subprocess.run([band_probe, *runtime_prefix(threads=1)],
            input=encode_request(query, bytes(changed), AlignConfig()),
            capture_output=True, check=True, timeout=60)
        values = [r.edit_distance for r in decode_batch(done.stdout, 9)]
        assert values[:4] == values[4:8] and values[8] == 1
        assert values[0] == edits
        assert not done.stderr


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_owned_band_batches_preserve_order_and_idle_owners(bend_binary, threads):
    rng = random.Random(833)
    with worker(bend_binary, threads, 4) as pooled:
        for length in (129, 257, 1025):
            query = bytes(rng.choices(range(256), k=length))
            targets = [bytes(rng.choices(range(256), k=(index * 39) % 513)) for index in range(129)]
            targets += [b"\0\xff" * 5001, b"", targets[3], query]
            config = AlignConfig(equalities=PAIRS)
            expected = pooled.align_batch([(query, t, config) for t in targets], timeout=60)
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                for values, wanted in [(targets, expected), (targets[:2], expected[:2]),
                                       ([], []), (targets[::-1], expected[::-1]), (targets, expected)]:
                    assert prepared.align_batch(values, timeout=60) == wanted
                    assert pooled.retained_bytes == retained
                assert prepared.align(query).edit_distance == 0
                assert pooled._owned_limit == 65536


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_advertised_query_limit_and_larger_query_fallback(bend_binary, threads):
    with worker(bend_binary, threads, 4) as pooled:
        for length in (65535, 65536, 65537):
            query = b"A" * length
            targets = [b"", b"A", b"N", b"C", b"\0\xff", query, query + b"Z"]
            config = AlignConfig(equalities=PAIRS)
            expected = pooled.align_batch([(query, t, config) for t in targets], timeout=60)
            with pooled.prepare(query, PAIRS) as prepared:
                assert prepared.align_batch(targets, timeout=60) == expected
                assert prepared.align(b"C").edit_distance == length
                assert pooled._owned_limit == 65536


def test_invalid_band_buffers_preserve_prepared_owner(packed_probe):
    done = subprocess.run([packed_probe, *runtime_prefix(threads=1), "band-bounds"],
        input=encode_request(b"A" * 257, b"A", AlignConfig()), capture_output=True, check=True, timeout=30)
    values = decode_batch(done.stdout, 4)
    assert [value.status for value in values] == [Status.ERROR, Status.OK, Status.ERROR, Status.OK]
    assert [values[i].edit_distance for i in (1, 3)] == [256, 256]
    assert not done.stderr


@pytest.mark.skipif(not Path("/proc/self/status").exists(), reason="Requires Linux memory accounting")
def test_owned_band_retries_do_not_accumulate_target_buffers(bend_binary):
    def resident(pid):
        text = Path(f"/proc/{pid}/status").read_text()
        return int(next(line.split()[1] for line in text.splitlines() if line.startswith("VmRSS:"))) * 1024

    rng = random.Random(994)
    query = bytes(rng.choices(range(256), k=257))
    targets = [bytes(rng.choices(range(256), k=512 + index % 5)) for index in range(128)]
    with worker(bend_binary, 4, 4) as pooled, pooled.prepare(query) as prepared:
        expected = prepared.align_batch(targets)
        for _ in range(32):
            assert prepared.align_batch(targets) == expected
        baseline, retained = resident(pooled.pid), pooled.retained_bytes
        for index in range(192):
            values, wanted = (targets, expected) if index % 2 else (targets[::-1], expected[::-1])
            assert prepared.align_batch(values) == wanted
        assert resident(pooled.pid) <= baseline + 8 * 1024 * 1024
        assert pooled.retained_bytes == retained


def test_forced_nat_and_production_attempts(band_probe, cpp_binary):
    """Independent owners avoid using the shared String helper as the oracle."""
    import itertools

    rng = random.Random(9202)
    tiny = [bytes(chars) for n in range(1, 4) for chars in itertools.product(b"\0\xff", repeat=n)]
    cases = list(itertools.product(tiny, repeat=2))
    for length in (*range(129, 161), 31, 32, 33, 63, 64, 65, 95, 96, 97,
                   127, 128, 129, 4096, 65535, 65536, 65537):
        query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
        changed = bytearray(query)
        for index in {0, min(32, length - 1), length // 2, length - 1}:
            changed[index] ^= 0x7f
        cases.extend((query, target) for target in (bytes(changed), query[1:] + b"Z", b"Z" + query, query[:-1]))
    cases.extend((bytes(rng.choices(range(256), k=rng.randrange(1, 301))),
                  bytes(rng.choices(range(256), k=rng.randrange(1, 301)))) for _ in range(80))
    for query, target in cases:
        optimum = (distance_dp(query, target, PAIRS) if max(len(query), len(target)) <= 300 else
                   cpp_edlib_align(query, target, AlignConfig(equalities=PAIRS), binary=cpp_binary).edit_distance)
        for maximum in sorted({0, max(0, optimum - 1), optimum, optimum + 1}):
            done = subprocess.run([band_probe, *runtime_prefix(threads=1), "attempt"],
                input=encode_request(query, target, AlignConfig(threshold=MaxDistance(maximum), equalities=PAIRS)),
                capture_output=True, check=True, timeout=60)
            values = [r.edit_distance for r in decode_batch(done.stdout, 18)]
            assert not done.stderr
            assert values[:4] == values[4:8] == values[9:13] == values[13:17], (len(query), len(target), maximum, values)
            assert values[8] == values[17] == 1
            assert values[0] == (optimum if optimum <= maximum else -1)


def test_each_column_matches_nat_control_and_complete_workspace(band_probe):
    rng = random.Random(2206)
    pairs = (*PAIRS, *reversed(PAIRS), *PAIRS)
    for length in (1, 31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128,
                   *range(129, 161), 193, 257, 4096):
        query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
        targets = [query, b"Z" * length, query[7:] + b"\xff\0" * 9,
                   b"Z" * 40 + query[:-3], query[::-1]]
        if length <= 257:
            targets.append(bytes(range(256)))
        for target in targets:
            for maximum in (0, 1, 2, 31, 32, 33, 63, 64, max(length, len(target))):
                done = subprocess.run([band_probe, *runtime_prefix(threads=1), "transitions"],
                    input=encode_request(query, target, AlignConfig(threshold=MaxDistance(maximum), equalities=pairs)),
                    capture_output=True, check=True, timeout=60)
                assert not done.stderr
                assert decode_batch(done.stdout, 1)[0].edit_distance == 1, (length, len(target), maximum)
