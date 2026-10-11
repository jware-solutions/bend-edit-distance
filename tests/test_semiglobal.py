"""Directional DP/Myers comparisons, without global metric assumptions."""

import itertools
import random

import pytest
from hypothesis import example, given, settings, strategies as st

from alignment import (
    AlignConfig, BeforeStart, DistanceFound, MaxDistance, Mode, Position,
    Task, Unlimited,
)
from tests.helpers import bend_align, cpp_edlib_align
from tests.test_configured_alignment import assert_valid_path


def compare(query, target, mode, bend_binary, dp_binary, cpp_binary, *, threads=1):
    config = AlignConfig(mode)
    optimum = bend_align(query, target, config, binary=dp_binary, threads=threads)
    distance = optimum.require_distance()
    thresholds = [Unlimited(), *(MaxDistance(k) for k in sorted({
        0, max(0, distance - 1), distance, distance + 1, 31, 32, 33, 63, 64, 65,
        4096,
    }))]
    for threshold in thresholds:
        config = AlignConfig(mode, threshold=threshold)
        dp = bend_align(query, target, config, binary=dp_binary, threads=threads)
        myers = bend_align(query, target, config, binary=bend_binary, threads=threads)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert myers == dp == expected, (query, target, config, myers, dp, expected)
    return optimum


@pytest.mark.parametrize("mode", [Mode.SHW, Mode.HW])
@pytest.mark.parametrize("query,target,distance,ends", [
    (b"AC", b"ACTTT", 0, (1,)),
    (b"AC", b"ACAC", 0, (1,)),
    (b"ACACTTT", b"AC", 5, (1,)),
    (b"AA", b"A", 1, (0,)),
    (b"A", b"CCC", 1, (-1, 0, 1, 2)),
    (b"", b"", 0, (-1,)),
    (b"", b"AC", 0, (-1,)),
    (b"AC", b"", 2, (-1,)),
])
def test_directional_boundaries(bend_binary, dp_binary, cpp_binary, mode,
                                query, target, distance, ends):
    # In HW, the second exact occurrence is also optimal.
    if mode == Mode.HW and target == b"ACAC":
        ends = (1, 3)
    if mode == Mode.SHW and query == b"A" and target == b"CCC":
        ends = (-1, 0)
    result = compare(query, target, mode, bend_binary, dp_binary, cpp_binary)
    assert result.distance == DistanceFound(distance)
    assert tuple(end.to_edlib() for end in result.end_locations) == ends


@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("mode,distance,starts,ends", [
    (Mode.SHW, 2, (0, 0, 0, 0), (-1, 0, 1, 3)),
    (Mode.HW, 0, (2, 6), (3, 7)),
])
def test_free_target_prefix_and_repeated_optima(bend_binary, cpp_binary, task,
                                               mode, distance, starts, ends):
    # SHW cannot skip TT. HW must find both matches even after k tightens to 0.
    for threshold in (Unlimited(), MaxDistance(0), MaxDistance(distance)):
        config = AlignConfig(mode, task, threshold)
        actual = bend_align(b"AC", b"TTACGGAC", config, binary=bend_binary)
        expected = cpp_edlib_align(b"AC", b"TTACGGAC", config, binary=cpp_binary)
        assert actual == expected
        if threshold == MaxDistance(0) and distance:
            assert actual.edit_distance == -1
            continue
        assert actual.edit_distance == distance
        assert tuple(end.to_edlib() for end in actual.end_locations) == ends
        if task != Task.DISTANCE:
            assert tuple(start.to_edlib() for start in actual.start_locations) == starts
        assert_valid_path(b"AC", b"TTACGGAC", config, actual)


@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 257])
@pytest.mark.parametrize("mode", [Mode.SHW, Mode.HW])
def test_word_boundaries_orientation_and_thresholds(bend_binary, dp_binary, cpp_binary, mode, length):
    query = (b"ACgt\0\xff" * 43)[:length]
    for target in (query + b"N" * 40, b"N" * 40 + query,
                   b"N" * 40 + query + b"N" * 35 + query,
                   query[:3], b"N" * length, query[1:] + query[:1]):
        compare(query, target, mode, bend_binary, dp_binary, cpp_binary)
        compare(target, query, mode, bend_binary, dp_binary, cpp_binary)


@pytest.mark.parametrize("length", [32, 64, 96, 128])
@pytest.mark.parametrize("mode", [Mode.SHW, Mode.HW])
def test_before_start_uses_pinned_word_convention(bend_binary, dp_binary, cpp_binary, length, mode):
    result = compare(b"A" * length, b"T" * 3, mode, bend_binary, dp_binary, cpp_binary)
    expected = (Position(0), Position(1), Position(2))
    if length % 64:
        expected = (BeforeStart(), *expected)
    assert result.end_locations == expected


def test_hw_recovers_after_long_rejected_prefix(bend_binary, dp_binary, cpp_binary):
    query = b"ACGT" * 33
    result = compare(query, b"N" * 1024 + query + b"N" * 40 + query,
                     Mode.HW, bend_binary, dp_binary, cpp_binary)
    assert result.distance == DistanceFound(0)
    assert result.end_locations == (Position(1155), Position(1327))


@pytest.mark.parametrize("mode", [Mode.SHW, Mode.HW])
def test_extreme_threshold_equals_unlimited(bend_binary, dp_binary, mode):
    # Pinned Edlib overflows k+1 at INT_MAX in its semiglobal band setup.
    # Check the mathematical contract against independent DP at that bound.
    for binary in (bend_binary, dp_binary):
        for query, target in ((b"AC", b"ACTTT"), (b"AC", b"TTACGGAC"), (b"A" * 65, b"T")):
            assert bend_align(query, target, AlignConfig(mode, threshold=MaxDistance(2**31 - 1)), binary=binary) == (
                bend_align(query, target, AlignConfig(mode), binary=binary))


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_every_padding_and_thread_count(bend_binary, dp_binary, cpp_binary, threads):
    rng = random.Random(20261010)
    for padding in range(32):
        query = bytes(rng.choices(range(256), k=96 - padding))
        target = b"\0\xff" * 20 + query[:33] + b"N" + query[36:] + query
        for mode in (Mode.SHW, Mode.HW):
            compare(query, target, mode, bend_binary, dp_binary, cpp_binary, threads=threads)


def test_exhaustive_ordered_small_inputs(bend_binary, dp_binary, cpp_binary):
    sequences = [bytes(s) for n in range(4) for s in itertools.product(b"AC", repeat=n)]
    for query, target, mode in itertools.product(sequences, sequences, (Mode.SHW, Mode.HW)):
        compare(query, target, mode, bend_binary, dp_binary, cpp_binary)


@settings(max_examples=80, deadline=None)
@given(query=st.binary(min_size=1, max_size=160),
       target=st.binary(min_size=1, max_size=260),
       mode=st.sampled_from([Mode.SHW, Mode.HW]))
@example(query=b"A" * 65, target=b"T" * 64 + b"A" * 65, mode=Mode.HW)
@example(query=b"A" * 96, target=b"T" * 3, mode=Mode.SHW)
def test_directional_differential_with_shrinking(bend_binary, dp_binary, cpp_binary, query, target, mode):
    compare(query, target, mode, bend_binary, dp_binary, cpp_binary)
