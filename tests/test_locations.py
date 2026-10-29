"""Task-dependent locations and HW start ties against pinned C++ Edlib."""

import itertools

import pytest

from alignment import (
    AlignConfig, AlignResult, BeforeStart, DistanceFound, DistanceNotFound,
    EqualityPair, MaxDistance, Mode, Operation, Position, Status, Task, Unlimited,
)
from tests.helpers import assert_valid_path, bend_align, cpp_edlib_align
from bend_runtime import runtime_prefix
from transport import AlignmentWorker


def coordinates(values):
    return tuple(BeforeStart() if v == -1 else Position(v) for v in values)


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("task", [Task.LOC, Task.PATH])
def test_hw_fixed_interval_starts_with_many_ties(bend_binary, cpp_binary, threads, task):
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    with AlignmentWorker([bend_binary, *runtime_prefix(threads=threads), "--worker"]) as worker:
        cases = [(b"A" * n, b"N" * (n + 513)) for n in [*range(1, 34), 63, 64, 65, 127, 128, 129]]
        cases += [(b"A", b"C" * 8193), (b"\0", b"\xff" * 8193),
                  (b"A" * 65, b"A" * 8193), (bytes(range(256)), bytes(range(256)) * 17)]
        for query, target in cases:
            config = AlignConfig(Mode.HW, task, equalities=pairs)
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            actual = worker.align(query, target, config)
            assert actual == expected
            assert_valid_path(query, target, config, actual)
            with worker.prepare(query, pairs) as prepared:
                values = [target, b"", target[:33], target]
                results = prepared.align_batch(values, config)
                assert results == [worker.align(query, value, config) for value in values]
                for value, result in zip(values, results):
                    oracle = cpp_edlib_align(query, value, config, binary=cpp_binary)
                    assert (result.status, result.distance, result.end_locations, result.start_locations) == (
                        oracle.status, oracle.distance, oracle.end_locations, oracle.start_locations)
                    assert_valid_path(query, value, config, result)
            accepted = AlignConfig(Mode.HW, task, MaxDistance(expected.require_distance()), pairs)
            assert worker.align(query, target, accepted) == actual
            if expected.require_distance():
                assert worker.align(query, target, AlignConfig(Mode.HW, task, MaxDistance(0), pairs)).edit_distance == -1


@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("mode,query,target,distance,ends,starts", [
    (Mode.NW, b"AC", b"TACGT", 3, (4,), (0,)),
    # NW's internal shorter-query swap must not change target coordinates.
    (Mode.NW, b"TACGT", b"AC", 3, (1,), (0,)),
    (Mode.SHW, b"AC", b"TTACGGAC", 2, (-1, 0, 1, 3), (0, 0, 0, 0)),
    (Mode.HW, b"AC", b"TTACGGAC", 0, (3, 7), (2, 6)),
    (Mode.HW, b"A", b"TT", 1, (-1, 0, 1), (0, 0, 1)),
])
def test_required_locations_and_absent_fields(
    bend_binary, cpp_binary, task, mode, query, target, distance, ends, starts,
):
    for threshold in (Unlimited(), MaxDistance(distance)):
        config = AlignConfig(mode, task, threshold)
        actual = bend_align(query, target, config, binary=bend_binary)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert actual == expected
        assert actual.status == Status.OK
        assert actual.distance == DistanceFound(distance)
        assert actual.end_locations == coordinates(ends)
        assert actual.start_locations == (None if task == Task.DISTANCE else coordinates(starts))
        if task == Task.PATH:
            assert actual.alignment is not None
            assert actual.cigar is not None
            assert_valid_path(query, target, config, actual)
        else:
            assert actual.alignment is None
            assert actual.cigar is None


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
def test_no_alignment_within_k_has_no_locations_or_requested_fields(
    bend_binary, cpp_binary, mode, task,
):
    config = AlignConfig(mode, task, MaxDistance(1))
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        result = align(b"AAA", b"TTT", config, binary=binary)
        assert result == AlignResult(Status.OK, DistanceNotFound(), (), None, None, None)
        assert result.to_edlib() == {
            "status": 0, "edit_distance": -1, "end_locations": [],
            "start_locations": None, "alignment": None, "cigar": None,
        }


@pytest.mark.parametrize("task", [Task.LOC, Task.PATH])
@pytest.mark.parametrize("query,target,distance,ends,starts", [
    # Mismatch and query-insertion starts tie. Upstream keeps the earliest.
    (b"ABC", b"XXBC", 1, (3,), (1,)),
    (b"AA", b"BA", 1, (1,), (0,)),
    (b"AAA", b"BA", 2, (1,), (0,)),
    # Each optimal end has its own start; a -1 end has upstream's start 0.
    (b"A", b"TTT", 1, (-1, 0, 1, 2), (0, 0, 1, 2)),
    (b"AC", b"TACGAC", 0, (2, 5), (1, 4)),
    # Byte equality must also apply to the reversed query profile.
    (b"\0\xff", b"X\0\xffY\0\xff", 0, (2, 5), (1, 4)),
])
def test_hw_start_selection_and_ties(
    bend_binary, cpp_binary, task, query, target, distance, ends, starts,
):
    for threshold in (Unlimited(), MaxDistance(distance)):
        config = AlignConfig(Mode.HW, task, threshold)
        actual = bend_align(query, target, config, binary=bend_binary)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert actual == expected
        assert actual.distance == DistanceFound(distance)
        assert actual.end_locations == coordinates(ends)
        assert actual.start_locations == coordinates(starts)
        assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129])
def test_hw_start_ties_across_words_and_parallel_branches(
    bend_binary, cpp_binary, threads, length,
):
    query = b"A" * length
    # Several tied ends, with many possible starts at each. Starts alternate
    # between retaining a mismatch and skipping a longer rejected prefix.
    target = b"B" + b"A" * (length - 1) + b"BB" + b"A" * (length - 1)
    for task in Task:
        config = AlignConfig(Mode.HW, task, MaxDistance(1))
        actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert (actual.status, actual.distance, actual.end_locations, actual.start_locations) == (
            expected.status, expected.distance, expected.end_locations, expected.start_locations)
        assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("task", list(Task))
def test_many_optimal_locations_keep_order_and_first_path(bend_binary, cpp_binary, task):
    query, target = b"AC", b"XAC" * 65
    config = AlignConfig(Mode.HW, task, MaxDistance(0))
    actual = bend_align(query, target, config, binary=bend_binary, threads=4)
    assert actual == cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert actual.end_locations == coordinates(range(2, len(target), 3))
    assert actual.start_locations == (
        None if task == Task.DISTANCE else coordinates(range(1, len(target), 3)))
    if task == Task.PATH:
        assert actual.alignment == (Operation.MATCH, Operation.MATCH)
        assert actual.cigar == "2="


def test_exhaustive_hw_starts_with_custom_equalities(bend_binary, cpp_binary):
    sequences = [bytes(s) for n in range(1, 4) for s in itertools.product(b"Aa", repeat=n)]
    for query, target in itertools.product(sequences, repeat=2):
        for pairs in ((), (EqualityPair(b"A", b"a"),)):
            config = AlignConfig(Mode.HW, Task.LOC, equalities=pairs)
            actual = bend_align(query, target, config, binary=bend_binary)
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            assert actual == expected, (query, target, config, actual, expected)
