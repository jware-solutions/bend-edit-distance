"""Differential thresholds and observable work in the production Myers band."""

from bend_runtime import runtime_prefix

import itertools
import random

import pytest
from hypothesis import example, given, settings, strategies as st

from alignment import AlignConfig, MaxDistance, Unlimited
from tests.helpers import bend_align, bend_dp_distance, cpp_edlib_align, execute


def search(binary, query, target, maximum, *, threads=1):
    result = execute([binary, *runtime_prefix(threads=threads), "search", str(maximum), query, target])
    assert result.stderr == ""
    return tuple(map(int, result.stdout.strip().split(",")))


def assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary, *, threads=1):
    # Scalar Bend DP does not import Myers, and supplies the optimum even for
    # finite k. Compare full oracle results, including absence of locations.
    distance = bend_dp_distance(query, target, binary=dp_binary, threads=threads)
    maxima = {0, max(0, distance - 1), distance, distance + 1, 31, 32, 33, 63, 64, 65,
              2**31 - 1}
    for threshold in [Unlimited(), *(MaxDistance(k) for k in sorted(maxima))]:
        config = AlignConfig(threshold=threshold)
        actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert actual == expected, (query, target, config, actual, expected)
        maximum = threshold.to_edlib()
        assert actual.edit_distance == (distance if maximum < 0 or distance <= maximum else -1)
    return distance


@pytest.mark.parametrize("length", [1, 31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 257])
def test_banded_word_boundaries(bend_binary, dp_binary, cpp_binary, length):
    query = (b"ACgt\0\xff" * 43)[:length]
    cases = [query, query[:-1] + b"N", b"N" + query, query[:1], b"N" * length,
             query[1:] + query[:1]]
    for target in cases:
        assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary)
        assert_thresholds(target, query, bend_binary, dp_binary, cpp_binary)


def test_banded_exhaustive_small_inputs(bend_binary, dp_binary, cpp_binary):
    sequences = [bytes(chars) for n in range(1, 4) for chars in itertools.product(b"AC", repeat=n)]
    for query, target in itertools.product(sequences, repeat=2):
        assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.parametrize("length", [31, 32, 33, 64, 65, 128, 129, 257])
def test_adaptive_search_matches_edlib(myers_probe, bend_binary, dp_binary, cpp_binary, length):
    query, target = "A" * length, "T" * length
    distance, *_ = search(myers_probe, query, target, -1)
    assert distance == length
    assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_seeded_indels_and_every_padding(bend_binary, dp_binary, cpp_binary, threads):
    rng = random.Random(20261010)
    for padding in range(32):
        query = bytes(rng.choices(range(256), k=160 - padding))
        # Deletions/insertions move across blocks, with a changed final score.
        target = query[9:67] + bytes(range(5)) + query[71:] + b"\0\xff"
        assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary, threads=threads)


@settings(max_examples=80, deadline=None)
@given(query=st.binary(min_size=1, max_size=260), target=st.binary(min_size=1, max_size=260))
@example(query=b"A" * 32 + b"C", target=b"A" * 33)
@example(query=b"A" * 129, target=b"T" * 129)
def test_banded_differential_with_shrinking(bend_binary, dp_binary, cpp_binary, query, target):
    assert_thresholds(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.parametrize("length", [1, 31, 32, 33, 63, 64, 65, 129, 257, 513])
def test_workspace_preserves_search_counters(myers_probe, length):
    rng = random.Random(357 + length)
    query = "".join(rng.choices("ACGT", k=length))
    for target in (query, "T" * length, query[7:] + "A" * 17, query[::-1]):
        for maximum in (-1, 0, length // 2, length):
            actual = execute(
                [myers_probe, *runtime_prefix(threads=1), "search", str(maximum), query, target])
            reference = execute([myers_probe, *runtime_prefix(threads=1), "search-reference", str(maximum), query, target])
            assert actual.stdout == reference.stdout


@pytest.mark.parametrize("lengths", [(1, 65), (65, 1), (31, 33), (33, 31), (64, 129), (129, 64), (128, 1024), (512, 1024)])
def test_both_profiled_orientations(myers_probe, bend_binary, cpp_binary, lengths):
    rng = random.Random(121 + sum(lengths))
    query, target = ["".join(rng.choices("ACGT", k=n)) for n in lengths]
    optimum = cpp_edlib_align(query, target, binary=cpp_binary).edit_distance
    for maximum in (-1, 0, optimum - 1, optimum, optimum + 1):
        for q, t in [(query, target), (target, query)]:
            result = execute([myers_probe, *runtime_prefix(threads=1), "search-profiled", str(maximum), q, t])
            assert int(result.stdout.split(",")[0]) == (optimum if maximum < 0 or maximum >= optimum else -1)
    assert bend_align(query, target, binary=bend_binary) == cpp_edlib_align(query, target, binary=cpp_binary)
