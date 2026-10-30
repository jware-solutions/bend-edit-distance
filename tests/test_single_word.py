"""Scalar prepared NW transitions, padding, ownership and fallback search."""

import random
import subprocess

import pytest

from alignment import AlignConfig, EqualityPair, MaxDistance, Mode, Task
from bend_runtime import runtime_prefix
from benchmarks.gpu_runner import decode_batch
from tests.helpers import ROOT, assert_valid_path, execute
from tests.test_cpu_pools import worker
from tests.test_small_paths import distance_dp
from transport import encode_request


PAIRS = (EqualityPair("A", "N"), EqualityPair("N", "C"),
         EqualityPair(0, 255), EqualityPair(128, 255))


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_single_word_prepared_calls_and_state_reset(bend_binary, threads):
    rng = random.Random(922)
    with worker(bend_binary, threads, 4) as pooled:
        for length in range(34):
            query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
            targets = [b"", query, query[::-1], bytes(range(256)), b"Z" * 512,
                       bytes(rng.choices(range(256), k=65)), b"\0\xff" * 16]
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                for task in Task:
                    for maximum in (None, 0, 1, 32):
                        config = AlignConfig(task=task, equalities=PAIRS) if maximum is None else AlignConfig(
                            task=task, threshold=MaxDistance(maximum), equalities=PAIRS)
                        expected = pooled.align_batch([(query, t, config) for t in targets])
                        actual = prepared.align_batch(targets, config)
                        assert actual == expected
                        for target, result in zip(targets, actual):
                            optimum = distance_dp(query, target, PAIRS)
                            accepted = maximum is None or optimum <= maximum or not query or not target
                            assert result.edit_distance == (optimum if accepted else -1)
                            assert_valid_path(query, target, config, result)
                        assert prepared.align(targets[3], config) == expected[3]
                for mode in (Mode.SHW, Mode.HW):
                    config = AlignConfig(mode, Task.PATH, equalities=PAIRS)
                    assert prepared.align(query, config) == pooled.align(query, query, config)
                assert prepared.align(query).edit_distance == 0
                assert pooled.retained_bytes == retained
        for byte in range(256):
            query = bytes([byte])
            targets = [query, bytes([(byte + 128) % 256]), b"\0", b"\x80", b"\xff", bytes(range(256))]
            with pooled.prepare(query, PAIRS) as prepared:
                for task in (Task.DISTANCE, Task.LOC):
                    config = AlignConfig(task=task, equalities=PAIRS)
                    results = prepared.align_batch(targets, config)
                    assert results == pooled.align_batch([(query, t, config) for t in targets])
                    assert [r.edit_distance for r in results] == [distance_dp(query, t, PAIRS) for t in targets]


@pytest.fixture(scope="module")
def single_word_probe(bend_tool):
    binary = ROOT / "build" / "single-word-probe"
    execute([bend_tool, ROOT / "tests/single_word_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_scalar_final_workspace_matches_banded_search(single_word_probe, threads):
    rng = random.Random(291)
    for length in range(1, 34):
        query = bytes(rng.choices(range(256), k=length))
        for target in (b"", query, bytes(range(256)), b"Z" * 4097):
            for maximum in (None, 0):
                config = AlignConfig(equalities=PAIRS) if maximum is None else AlignConfig(
                    threshold=MaxDistance(maximum), equalities=PAIRS)
                result = subprocess.run([single_word_probe, *runtime_prefix(threads=threads)],
                    input=encode_request(query, target, config), capture_output=True, check=True, timeout=30)
                scalar, reference, same_state = decode_batch(result.stdout, 3)
                assert scalar == reference
                assert same_state.edit_distance == 1
                assert result.stderr == b""
