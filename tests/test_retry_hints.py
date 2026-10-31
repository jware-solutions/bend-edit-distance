"""Bounded diagonal witnesses, adaptive counters and prepared-state reuse."""

import random
import subprocess

import pytest

from alignment import AlignConfig, EqualityPair, MaxDistance, Mode, Task
from benchmarks.gpu_runner import decode_batch
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, assert_valid_path, execute
from tests.test_cpu_pools import worker
from transport import encode_request


PAIRS = (EqualityPair("A", "N"), EqualityPair("N", "C"),
         EqualityPair(0, 255), EqualityPair(128, 255))
EDGES = {(65, 78), (78, 65), (78, 67), (67, 78),
         (0, 255), (255, 0), (128, 255), (255, 128)}


@pytest.fixture(scope="module")
def hint_probe(bend_tool):
    binary = ROOT / "build/retry-hint-probe"
    execute([bend_tool, ROOT / "tests/retry_hint_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_diagonal_bounds_match_direct_equalities_and_preserve_profile(hint_probe, bend_binary, threads):
    rng = random.Random(953)
    with worker(bend_binary, threads, 4) as reference:
        for length in (*range(130), 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097):
            alphabet = b"ACN\0\x80\xff" if length % 2 else bytes(range(256))
            query = bytes(rng.choices(alphabet, k=length))
            targets = [query, query[::-1], bytes(rng.choices(alphabet, k=length)), query[:-1], query + b"Z"]
            for edits in (length // 8, length // 8 + 1):
                changed = bytearray(query)
                for index in rng.sample(range(length), min(length, edits)):
                    changed[index] ^= 0x55
                targets.append(bytes(changed))
            for target in targets:
                config = AlignConfig(equalities=PAIRS)
                done = subprocess.run([hint_probe, *runtime_prefix(threads=threads)],
                    input=encode_request(query, target, config), capture_output=True, check=True, timeout=60)
                hint, reused = decode_batch(done.stdout, 2)
                diagonal = sum(a != b and (a, b) not in EDGES for a, b in zip(query, target))
                expected = diagonal if len(target) == length and diagonal <= length // 8 else -1
                assert hint.edit_distance == expected, (length, len(target))
                assert reused == reference.align(query, target, config)
                assert not done.stderr


def test_hint_counters_preserve_fallback_and_skip_retries(hint_probe):
    rng = random.Random(224)
    retained, changed = 0, 0
    for length in (1024, 2048, 4096, 4097, 16384):
        query = bytes(rng.choices(b"ACGT", k=length))
        for rate in (0, .002, .0082, .015, .02, .05, .15, .75):
            target = bytearray(query)
            for index in rng.sample(range(length), int(length * rate)):
                target[index] ^= 0x55
            target = bytes(target)
            done = subprocess.run([hint_probe, *runtime_prefix(threads=1), "stats"],
                input=encode_request(query, target, AlignConfig()), capture_output=True, check=True, timeout=60)
            values = [r.edit_distance for r in decode_batch(done.stdout, 12)]
            hinted, plain, first = values[:4], values[4:8], values[8:]
            assert hinted[0] == plain[0]
            limit = min(length // 8, max(256, length // 32))
            useful = length * 32 // limit <= first[2] and 2 * first[2] < length
            diagonal = sum(a != b for a, b in zip(query, target))
            if first[0] >= 0 or not useful or diagonal > limit:
                assert hinted == plain, (length, rate, hinted, plain, first)
                retained += 1
            else:
                assert hinted[3] == 2 and hinted[3] <= plain[3]
                changed += hinted[3] < plain[3]
            assert not done.stderr
    assert retained and changed


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_prepared_retries_match_ordinary_calls_and_reset_for_other_options(bend_binary, threads):
    rng = random.Random(874)
    with worker(bend_binary, threads, 4) as pooled:
        for length in (1023, 1024, 1025, 4096, 4097):
            query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
            targets = [query, query[::-1], query[1:] + b"Z", b"Z" + query[:-1], query[:-1], query + b"Z", b""]
            for edits in (31, 32, 33, 63, 64, 65, 80, 200):
                target = bytearray(query)
                for index in rng.sample(range(length), edits):
                    target[index] ^= 0x55
                targets.append(bytes(target))
            config = AlignConfig(equalities=PAIRS)
            expected = pooled.align_batch([(query, t, config) for t in targets], timeout=60)
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                for values, wanted in [(targets, expected), (targets[::-1], expected[::-1]), ([], [])]:
                    assert prepared.align_batch(values, timeout=60) == wanted
                for target, result in zip(targets, expected):
                    optimum = result.edit_distance
                    for maximum in (max(0, optimum - 1), optimum, optimum + 1):
                        finite = AlignConfig(threshold=MaxDistance(maximum), equalities=PAIRS)
                        assert prepared.align(target, finite, timeout=60) == pooled.align(query, target, finite, timeout=60)
                for mode in Mode:
                    for task in (Task.LOC, Task.PATH):
                        options = AlignConfig(mode, task, equalities=PAIRS)
                        target = targets[-2]
                        actual = prepared.align(target, options, timeout=60)
                        assert actual == pooled.align(query, target, options, timeout=60)
                        assert_valid_path(query, target, options, actual)
                assert prepared.align(query).edit_distance == 0
                assert pooled.retained_bytes == retained
