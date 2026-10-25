"""Full result comparisons against the pinned Edlib oracle."""


from dataclasses import replace
import itertools

import pytest
from hypothesis import given, settings, strategies as st

from alignment import (
    AlignConfig, AlignResult, BeforeStart, CigarFormat, DistanceFound,
    DistanceNotFound, EqualityPair, MaxDistance, Mode, Operation, Position,
    Status, Task, Unlimited,
)
from tests.helpers import assert_valid_path, bend_align, cpp_edlib_align, execute


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("threshold", [Unlimited(), MaxDistance(0), MaxDistance(2)])
@pytest.mark.parametrize("query,target", [
    ("", ""), ("", "AC"), ("AC", ""), ("AC", "TACGAC"),
    ("A", "TT"), ("AC", "CA"), ("AA", "AAA"), ("aN", "ACaN"),
])
def test_modes_tasks_thresholds(bend_binary, cpp_binary, mode, task, threshold, query, target):
    config = AlignConfig(mode, task, threshold)
    actual = bend_align(query, target, config, binary=bend_binary)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert actual == expected, (query, target, config, actual, expected)


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("query,target", [
    ("aAN", "AAA"), ("AN", "NA"), ("N", "T"), ("a", "N"),
    ("--", "\t\n"), ("ACG", "AT"),
])
def test_equalities_and_cigar(bend_binary, cpp_binary, mode, task, format, query, target):
    config = AlignConfig(mode, task, equalities=(
        EqualityPair("a", "A"), EqualityPair("A", "N"),
        EqualityPair("N", "C"), EqualityPair("-", "\t"),
    ), cigar_format=format)
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


def test_distance_includes_all_ends(bend_binary, cpp_binary):
    config = AlignConfig(mode=Mode.HW)
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        result = align("A", "ATA", config, binary=binary)
        assert result.status == Status.OK
        assert result.distance == DistanceFound(0)
        assert result.end_locations == (Position(0), Position(2))
        assert result.start_locations is None
        assert result.alignment is None
        assert result.cigar is None


def test_oracle_default_call_is_structured(cpp_binary):
    result = AlignResult.from_json(execute([cpp_binary, "AC", "A"]).stdout)
    assert result == AlignResult(Status.OK, DistanceFound(1), (Position(0),), None, None, None)


@pytest.mark.parametrize("query,target", [
    ("--config", "--threads"), ("\t\n '\"$()*", "\n\t"),
    ("\x01\x7f", "\x7f\x01"),
])
def test_structured_literal_argv(bend_binary, cpp_binary, query, target):
    config = AlignConfig(task=Task.PATH, equalities=(EqualityPair("'", '"'), EqualityPair("\x01", "\x7f")))
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


def test_missing_distance_and_negative_coordinate_are_distinct(bend_binary, cpp_binary):
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        missing = align("A", "C", AlignConfig(threshold=MaxDistance(0)), binary=binary)
        assert missing == AlignResult(Status.OK, DistanceNotFound(), (), None, None, None)
        assert missing.to_edlib()["edit_distance"] == -1
        empty = align("A", "", binary=binary)
        assert empty.distance == DistanceFound(1)
        assert empty.end_locations == (BeforeStart(),)
        assert empty.to_edlib()["end_locations"] == [-1]


def test_threshold_boundary(bend_binary, cpp_binary):
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        config = AlignConfig(task=Task.PATH, threshold=MaxDistance(1))
        found = align("AC", "AG", config, binary=binary)
        assert found.distance == DistanceFound(1)
        assert found.cigar == "1=1X"
        assert isinstance(align("AC", "AG", replace(config, threshold=MaxDistance(0)),
                                binary=binary).distance, DistanceNotFound)


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 127, 128, 129])
def test_configured_word_boundaries(bend_binary, cpp_binary, threads, length):
    for mode in Mode:
        for query, target in (("A" * length, "T" * 3), ("A" * length, "T" + "A" * length + "T")):
            config = AlignConfig(mode, Task.LOC)
            actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            assert actual == expected, (length, config, actual, expected)


def test_operation_codes_and_cigar_formats(bend_binary, cpp_binary):
    cases = [
        ("AC", "AG", (Operation.MATCH, Operation.MISMATCH), "1=1X", "2M"),
        ("AC", "A", (Operation.MATCH, Operation.INSERT), "1=1I", "1M1I"),
        ("A", "AC", (Operation.MATCH, Operation.DELETE), "1=1D", "1M1D"),
    ]
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        for query, target, operations, extended, standard in cases:
            for format, cigar in ((CigarFormat.EXTENDED, extended), (CigarFormat.STANDARD, standard)):
                result = align(query, target, AlignConfig(task=Task.PATH, cigar_format=format), binary=binary)
                assert result.alignment == operations
                assert result.cigar == cigar


def test_empty_inputs_preserve_pinned_edlib_behavior(bend_binary, cpp_binary):
    # The upstream empty-input early return ignores k and skips LOC/PATH work.
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        result = align("AC", "", AlignConfig(task=Task.PATH, threshold=MaxDistance(0)), binary=binary)
        assert result == AlignResult(Status.OK, DistanceFound(2), (BeforeStart(),), None, None, None)


@settings(max_examples=50, deadline=None, derandomize=True)
@given(query=st.text("AaCN", min_size=1, max_size=80),
       target=st.text("AaCN", min_size=1, max_size=80),
       mode=st.sampled_from(list(Mode)), task=st.sampled_from(list(Task)),
       threshold=st.one_of(st.just(Unlimited()), st.integers(0, 80).map(MaxDistance)),
       pairs=st.sampled_from([(), (EqualityPair("a", "A"), EqualityPair("N", "A"))]))
def test_configured_differential(bend_binary, cpp_binary, query, target, mode, task, threshold, pairs):
    config = AlignConfig(mode, task, threshold, pairs)
    actual = bend_align(query, target, config, binary=bend_binary)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert (actual.status, actual.distance, actual.end_locations, actual.start_locations) == (
        expected.status, expected.distance, expected.end_locations, expected.start_locations)
    # Edlib may use Hirschberg on larger matrices and choose another optimal path.
    assert_valid_path(query, target, config, actual)
    assert_valid_path(query, target, config, expected)


@pytest.mark.alignment
def test_exhaustive_configured_small_inputs(bend_binary, cpp_binary):
    sequences = ["".join(s) for n in range(4) for s in itertools.product("AC", repeat=n)]
    for query, target, mode, task in itertools.product(sequences, sequences, Mode, Task):
        config = AlignConfig(mode, task)
        assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
            query, target, config, binary=cpp_binary), (query, target, config)
