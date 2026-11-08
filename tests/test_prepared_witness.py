"""Exact admitted low-edit witnesses preserve prepared results and search state."""

import itertools
from pathlib import Path

import pytest

from alignment import AlignConfig, CigarFormat, MaxDistance, Mode, Task
from tests.helpers import cpp_edlib_align
from tests.test_cpu_pools import worker
from tests.test_retry_hints import PAIRS, EDGES
from tests.test_prepared_bytes import packed_probe


def changed(query, positions):
    target = bytearray(query)
    for position in positions:
        target[position] ^= 0x55
    return bytes(target)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_witness_all_bytes_padding_and_direct_equalities(bend_binary, cpp_binary, threads):
    config = AlignConfig(equalities=PAIRS)
    with worker(bend_binary, threads, 4) as pooled:
        for padding in range(32):
            query = bytes(range(256)) + bytes(range(padding))
            targets, distances = [query], [0]
            for symbol in range(256):
                position = (symbol * 17 + 7 + padding) % len(query)
                target = bytearray(query)
                target[position] = symbol
                targets.append(bytes(target))
                distances.append(int(query[position] != symbol and (query[position], symbol) not in EDGES))
            for position in (0, 31, 32, 63, 64, len(query) - 1):
                targets.append(changed(query, [position]))
                distances.append(1)
            equivalent = bytearray(query)
            for position, symbol in ((0, 255), (65, 78), (67, 78), (78, 65), (128, 255), (255, 128)):
                equivalent[position] = symbol
            targets += [bytes(equivalent), changed(bytes(equivalent), [1])]
            distances += [0, 1]
            # These pairs have a common neighbor but are not directly equal.
            for position, symbol in ((0, 128), (65, 67)):
                target = bytearray(query)
                target[position] = symbol
                targets.append(bytes(target))
                distances.append(1)
            targets += [changed(query, [31, 32]), changed(query, [32, 33]),
                        changed(query, [len(query) - 2, len(query) - 1]),
                        query[1:] + query[:1], query[:-1], query + b"Z", b""]
            distances += [2, 2, 2, 2, 1, 1, len(query)]
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                results = prepared.align_batch(targets, timeout=60)
                assert [r.edit_distance for r in results] == distances
                for target, result in zip(targets, results):
                    assert tuple(p.to_edlib() for p in result.end_locations) == (len(target) - 1,)
                    assert result.start_locations is result.alignment is result.cigar is None
                for index in (1, 129, 256, len(targets) - 8):
                    assert results[index] == cpp_edlib_align(query, targets[index], config, binary=cpp_binary)
                assert prepared.align(query).edit_distance == 0
                assert pooled.retained_bytes == retained


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_witness_reuses_state_across_fallbacks_and_options(bend_binary, cpp_binary, threads):
    with worker(bend_binary, threads, 4) as pooled:
        for length in (127, 128, 129, 130, 255, 256, 257, 287, 288, 1024,
                       4095, 4096, 4097, 16384, 65535, 65536, 65537):
            query = (b"AC" * ((length + 1) // 2))[:length]
            one, two = changed(query, [length // 2]), changed(query, [31, 32])
            shifted = query[1:] + query[:1]
            targets = [query, one, b"N" * length, two, shifted, query[:-1], query + b"Z", b""]
            expected = [0, 1, 0, 2, 2, 1, 1, length]
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                for values, wanted in ((targets, expected), (targets[::-1], expected[::-1]), (targets, expected)):
                    assert [r.edit_distance for r in prepared.align_batch(values, timeout=120)] == wanted
                if length in (129, 257, 4097):
                    for maximum in (0, 1, 2, 3):
                        config = AlignConfig(threshold=MaxDistance(maximum), equalities=PAIRS)
                        for target in (one, two):
                            assert prepared.align(target, config) == cpp_edlib_align(query, target, config, binary=cpp_binary)
                        assert prepared.align(query).edit_distance == 0
                        assert prepared.align(shifted).edit_distance == 2
                    for mode, task, format in itertools.product(Mode, Task, CigarFormat):
                        config = AlignConfig(mode, task, equalities=PAIRS, cigar_format=format)
                        for target in (one, two):
                            assert prepared.align(target, config, timeout=120) == cpp_edlib_align(query, target, config, binary=cpp_binary)
                        assert prepared.align(query).edit_distance == 0
                        assert prepared.align(two).edit_distance == 2
                assert pooled.retained_bytes == retained


@pytest.mark.skipif(not Path("/proc/self/status").exists(), reason="Requires Linux memory accounting")
def test_witness_scans_do_not_retain_target_buffers(bend_binary):
    def resident(pid):
        text = Path(f"/proc/{pid}/status").read_text()
        return int(next(line.split()[1] for line in text.splitlines() if line.startswith("VmRSS:"))) * 1024

    query = b"ACGT" * 1024
    targets = [changed(query, [index * 31]) if index % 3 else changed(query, [32, 33]) for index in range(32)]
    targets += [query, b"", query + b"Z"]
    with worker(bend_binary, 4, 4) as pooled, pooled.prepare(query) as prepared:
        expected = prepared.align_batch(targets)
        for _ in range(16):
            assert prepared.align_batch(targets) == expected
        baseline, retained = resident(pooled.pid), pooled.retained_bytes
        for index in range(96):
            values, wanted = (targets, expected) if index % 2 else (targets[::-1], expected[::-1])
            assert prepared.align_batch(values) == wanted
            assert pooled.retained_bytes == retained
        assert resident(pooled.pid) <= baseline + 8 * 1024 * 1024


def probe(packed_probe, kind, query, target, pairs=()):
    import subprocess
    from benchmarks.gpu_runner import decode_batch
    from bend_runtime import runtime_prefix
    from transport import encode_request
    done = subprocess.run([packed_probe, *runtime_prefix(threads=1), kind],
                          input=encode_request(query, target, AlignConfig(equalities=pairs)),
                          capture_output=True, check=True, timeout=60)
    assert not done.stderr
    return decode_batch(done.stdout, 2 if kind == "witness-owner" else 1)


def test_exhaustive_certificates_against_scalar_dp(packed_probe, bend_binary):
    from alignment import EqualityPair
    from tests.test_small_paths import distance_dp
    variants = ((), PAIRS + (EqualityPair("N", "A"), EqualityPair("A", "N"), EqualityPair("A", "A")))
    with worker(bend_binary, 1, 1) as pooled:
        for pairs in variants:
            edges = {tuple(p.to_bytes()) for p in pairs}
            edges |= {(b, a) for a, b in edges}
            for alphabet, maximum in ((b"AC", 4), (b"ANC", 3)):
                for length in range(maximum + 1):
                    words = [bytes(w) for w in itertools.product(alphabet, repeat=length)]
                    for query in words:
                        # Disjoint padding lifts the exhaustive core into the owned route.
                        padded = b"\xff" * 32 + query + b"\xfe" * 97
                        with pooled.prepare(padded, pairs) as owner:
                            results = owner.align_batch([b"\xff" * 32 + t + b"\xfe" * 97 for t in words])
                        for target, result in zip(words, results):
                            optimum = distance_dp(query, target, pairs)
                            assert result == pooled.align(padded, b"\xff" * 32 + target + b"\xfe" * 97, AlignConfig(equalities=pairs))
                            assert result.edit_distance == optimum
                            diagonal = sum(a != b and (a, b) not in edges for a, b in zip(query, target))
                            hint = probe(packed_probe, "witness-math", query, target, pairs)[0]
                            admitted = probe(packed_probe, "witness", padded, b"\xff" * 32 + target + b"\xfe" * 97, pairs)[0]
                            assert admitted.edit_distance == (diagonal if diagonal <= 1 else -1)
                            assert hint.edit_distance == (diagonal if diagonal <= 2 else -1)
                            if hint.edit_distance >= 0:
                                assert hint.edit_distance == optimum


def test_two_diagonal_bounds_and_stale_owner_preservation(packed_probe):
    for padding in range(32):
        query = bytes(range(256)) + bytes(range(padding))
        for positions in ((), (0,), (0, 1), (31, 32), (32, 33), (63, 64),
                          (64, 65), (len(query) // 2, len(query) - 1), (len(query) - 2, len(query) - 1)):
            target = changed(query, positions)
            result, preserved = probe(packed_probe, "witness-owner", query, target)
            assert result.edit_distance == len(positions)
            certificate = probe(packed_probe, "witness", query, target)[0]
            assert certificate.edit_distance == (len(positions) if len(positions) <= 1 else -1)
            if certificate.edit_distance >= 0:
                assert certificate.edit_distance == result.edit_distance
                assert preserved.edit_distance == 1
        # The second mismatch is already reached; the third is last in scan order.
        for positions in ((0, 1, 32), (32, 63, 64)):
            failed = changed(query, positions)
            assert probe(packed_probe, "witness", query, failed)[0].edit_distance == -1


def test_three_diagonal_mismatches_do_not_reject_edit_two(packed_probe, bend_binary):
    from tests.test_small_paths import distance_dp
    with worker(bend_binary, 1, 1) as pooled:
        for a, b in ((b"ABC", b"BCA"), (b"AAAB", b"AABA"), (b"ABAB", b"BABA"),
                     (b"AAAAABBBB", b"AAAABBBBA")):
            query, target = b"\xff" * 129 + a, b"\xff" * 129 + b
            optimum = distance_dp(a, b, ())
            assert optimum == 2
            with pooled.prepare(query) as owner:
                assert owner.align(target) == pooled.align(query, target)
                assert owner.align(target).edit_distance == 2
            if sum(x != y for x, y in zip(a, b)) > 2:
                assert probe(packed_probe, "witness", query, target)[0].edit_distance == -1
