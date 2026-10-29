"""Path semantics, explicit DP ties, and independent Hirschberg reconstruction."""

from bend_runtime import runtime_prefix

from dataclasses import replace
import itertools

import pytest
from hypothesis import given, settings, strategies as st

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Operation, Task
from tests.helpers import ROOT, assert_valid_path, bend_align, cpp_edlib_align
from transport import cached_worker


def probe_align(binary, algorithm, query, target, config, threads=1):
    worker = cached_worker(
        [binary, *runtime_prefix(threads=threads), algorithm, "--worker"], cwd=ROOT,
    )
    return worker.align(query, target, config, timeout=30)


def assert_same_locations(actual, expected):
    assert (actual.status, actual.distance, actual.end_locations, actual.start_locations) == (
        expected.status, expected.distance, expected.end_locations, expected.start_locations)


def test_dp_traceback_exact_upstream_small_ties(reconstruction_probe, cpp_binary):
    sequences = [bytes(s) for n in range(1, 4) for s in itertools.product(b"AC", repeat=n)]
    config = AlignConfig(task=Task.PATH)
    for query, target in itertools.product(sequences, repeat=2):
        actual = probe_align(reconstruction_probe, "dp", query, target, config)
        assert actual == cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("algorithm", ["dp", "indexed", "divide", "auto", "known"])
@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("query,target", [
    (b"", b""), (b"", b"AC"), (b"AC", b""),
    (b"A", b"B" * 130), (b"B" * 130, b"A"),
    (b"AC" * 32, b"CA" * 32),
    (b"A" * 129, b"A" * 128),
    (b"ACGT" * 65, b"CGAT" * 64),
    (b"a\0\x80NC" * 27, b"A\xff\x7fAC" * 26),
])
def test_dp_and_divide_paths_consume_inputs_and_match_optimum(
    reconstruction_probe, cpp_binary, algorithm, threads, query, target,
):
    config = AlignConfig(task=Task.PATH, equalities=(
        EqualityPair("a", "A"), EqualityPair("N", "A"),
        EqualityPair(0, 255), EqualityPair(128, 127),
    ))
    actual = probe_align(reconstruction_probe, algorithm, query, target, config, threads)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert actual.distance == expected.distance
    assert_valid_path(query, target, config, actual)


def test_optimal_path_semantics_are_separate_from_exact_ties(reconstruction_probe, cpp_binary):
    query, target = b"A" * 129, b"A" * 128
    config = AlignConfig(task=Task.PATH)
    dp = probe_align(reconstruction_probe, "dp", query, target, config)
    divided = probe_align(reconstruction_probe, "auto", query, target, config)
    assert dp == cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert_same_locations(divided, dp)
    assert divided.alignment != dp.alignment
    for result in (dp, divided):
        assert_valid_path(query, target, config, result)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_indexed_traceback_preserves_all_dp_ties(reconstruction_probe, threads):
    import random
    rng = random.Random(831)
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    config = AlignConfig(task=Task.PATH, equalities=pairs)
    cases = [(bytes(q), bytes(t)) for q in itertools.product((0, 128, 255), repeat=2)
             for t in itertools.product((0, 128, 255), repeat=2)]
    for n in (0, 1, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 129):
        cases.append((bytes(rng.choices(b"ACN\0\xff", k=n)), bytes(rng.choices(b"ACN\0\xff", k=n + 3))))
    cases.extend([(b"N", bytes(range(256)) * 20), (bytes(range(256)) * 20, b"N")])
    for query, target in cases:
        actual = probe_align(reconstruction_probe, "indexed", query, target, config, threads)
        assert actual == probe_align(reconstruction_probe, "dp", query, target, config, threads)
        assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("format", list(CigarFormat))
def test_known_zero_and_one_edit_paths(bend_binary, cpp_binary, mode, threads, format):
    import random
    rng = random.Random(922)
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"),
             EqualityPair(0, 255), EqualityPair(128, 127))
    config = AlignConfig(mode, Task.PATH, equalities=pairs, cigar_format=format)
    for length in [*range(1, 34), 63, 64, 65, 127, 128, 129, 4097, 8193]:
        query = bytes(rng.choices(range(256), k=length))
        for edited in (False, True):
            segment = bytearray(query)
            if edited:
                segment[length // 2] ^= 0x55
            target = (b"prefix" if mode == Mode.HW else b"") + bytes(segment)
            if mode != Mode.NW:
                target += b"suffix"
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            assert expected.require_distance() <= 1
            actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
            assert actual == expected
            assert_valid_path(query, target, config, actual)
            accepted = replace(config, threshold=MaxDistance(expected.require_distance()))
            assert bend_align(query, target, accepted, binary=bend_binary, threads=threads) == actual
            if expected.require_distance():
                missing = bend_align(query, target, replace(config, threshold=MaxDistance(0)),
                                     binary=bend_binary, threads=threads)
                assert missing.edit_distance == -1
                assert missing.alignment is None


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("length", [63, 64, 65, 127, 128, 129, 257])
def test_public_paths_across_dp_cutoff_and_multiple_splits(bend_binary, cpp_binary, threads, mode, length):
    query = (b"ACGT" * 65)[:length]
    segment = b"T" + query[1:32] + b"G" + query[32:64] + query[65:]
    target = (b"XX" if mode == Mode.HW else b"") + segment + b"ZZ"
    config = AlignConfig(mode, Task.PATH)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
    assert_same_locations(actual, expected)
    assert_valid_path(query, target, config, actual)
    assert_valid_path(query, target, config, expected)
    # A successful finite threshold produces the same path; a lower one skips it.
    accepted = replace(config, threshold=MaxDistance(expected.require_distance()))
    assert bend_align(query, target, accepted, binary=bend_binary, threads=threads) == actual
    if expected.require_distance():
        rejected = replace(config, threshold=MaxDistance(expected.require_distance() - 1))
        missing = bend_align(query, target, rejected, binary=bend_binary, threads=threads)
        assert missing.edit_distance == -1
        assert missing.alignment is None and missing.cigar is None


@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("query,target", [
    (b"A" * 4097, b"AAA"), (b"AAA", b"A" * 4097),
    (b"ACGT" * 256, b"AGCT" * 256),
    (bytes(range(256)) * 2, bytes(reversed(range(256))) * 2),
])
def test_large_and_skewed_public_paths(bend_binary, cpp_binary, threads, query, target):
    config = AlignConfig(task=Task.PATH)
    actual = bend_align(query, target, config, binary=bend_binary, threads=threads, timeout=30)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary, timeout=30)
    assert_same_locations(actual, expected)
    assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("mode", [Mode.SHW, Mode.HW])
def test_path_uses_first_location_with_a_different_later_interval(bend_binary, cpp_binary, mode):
    query = b"A" * 129
    target = b"B" * 130 if mode == Mode.SHW else b"A" * 128 + b"BB" + b"A" * 128
    config = AlignConfig(mode, Task.PATH)
    actual = bend_align(query, target, config, binary=bend_binary, threads=4)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert_same_locations(actual, expected)
    assert len(actual.end_locations) > 1
    assert_valid_path(query, target, config, actual)
    if mode == Mode.SHW:
        assert actual.end_locations[0].to_edlib() == -1
        assert actual.alignment == (Operation.INSERT,) * len(query)
    else:
        # The first interval is shorter than the query and needs an insertion;
        # later intervals can consume 129 symbols using a mismatch instead.
        assert actual.end_locations[0].to_edlib() == 127
        assert actual.alignment.count(Operation.INSERT) == 1
        assert Operation.MISMATCH not in actual.alignment


@settings(max_examples=60, deadline=None, derandomize=True)
@given(query=st.binary(min_size=64, max_size=160), target=st.binary(min_size=64, max_size=160),
       mode=st.sampled_from(list(Mode)), format=st.sampled_from(list(CigarFormat)),
       pairs=st.sampled_from([(), (EqualityPair(0, 255), EqualityPair(128, 255)),
                             (EqualityPair("a", "A"), EqualityPair("A", "N"))]))
def test_large_byte_paths_with_equalities(bend_binary, cpp_binary, query, target, mode, format, pairs):
    config = AlignConfig(mode, Task.PATH, equalities=pairs, cigar_format=format)
    actual = bend_align(query, target, config, binary=bend_binary, threads=4)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert_same_locations(actual, expected)
    assert_valid_path(query, target, config, actual)
    assert_valid_path(query, target, config, expected)
