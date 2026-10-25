"""Configured equality pairs across scalar DP, Myers profiles and pinned Edlib."""

from bend_runtime import runtime_prefix

from dataclasses import replace

import pytest
from hypothesis import given, settings, strategies as st

from alignment import (
    AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Operation, Task, Unlimited,
)
from tests.helpers import bend_align, cpp_edlib_align, execute


CASE_PAIRS = tuple(EqualityPair(c, c + 32) for c in range(ord("A"), ord("Z") + 1))
WILDCARD_PAIRS = tuple(EqualityPair("N", c) for c in "ACGT")
BYTE_PAIRS = (EqualityPair(0, 255), EqualityPair(127, 128), EqualityPair(128, 255))


def assert_distances(query, target, config, bend_binary, dp_binary, cpp_binary, threads=1):
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    for binary in (dp_binary, bend_binary):
        actual = bend_align(query, target, config, binary=binary, threads=threads)
        assert actual == expected, (query, target, config, threads, binary, actual, expected)
    return expected


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("threshold", [Unlimited(), MaxDistance(0), MaxDistance(1)])
@pytest.mark.parametrize("query,target,pairs", [
    (b"aBcDeZ", b"AbCdEz", CASE_PAIRS),
    (b"ANNT", b"ACGT", WILDCARD_PAIRS),
    (b"ACGT", b"NNNN", WILDCARD_PAIRS),
    (b"A", b"C", WILDCARD_PAIRS),  # N=A and N=C do not make A=C.
    (b"a", b"N", (EqualityPair("a", "A"), EqualityPair("A", "N"))),
    (b"aA", b"Aa", (EqualityPair("A", "a"),) * 3 +
     (EqualityPair("a", "A"), EqualityPair("A", "A"))),
    (b"\0\x7f\x80\xff", b"\xff\x80\x7f\0", BYTE_PAIRS),
    (b"\0", b"\x80", BYTE_PAIRS),  # 0=255 and 255=128 do not make 0=128.
    (b"AC", b"GT", (EqualityPair("N", "A"), EqualityPair(0, 255))),
    (b"NN", b"NN", (EqualityPair("A", "A"),)),  # Literal equality remains.
    (b"", b"\0\xff", BYTE_PAIRS),
    (b"\xff\0", b"", BYTE_PAIRS),
])
def test_equality_distance_contract(bend_binary, dp_binary, cpp_binary,
                                    mode, threads, threshold, query, target, pairs):
    assert_distances(query, target, AlignConfig(mode, threshold=threshold, equalities=pairs),
                     bend_binary, dp_binary, cpp_binary, threads)


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129])
def test_equality_word_boundaries(bend_binary, dp_binary, cpp_binary, mode, threads, length):
    pairs = (EqualityPair("a", "A"), EqualityPair("N", "a"),
             EqualityPair(0, 255), EqualityPair(128, 127))
    query = (b"aN\0\x80C" * 26)[:length]
    matched = (b"Aa\xff\x7fC" * 26)[:length]
    target = b"T" + matched[:32] + b"G" + matched[33:] + b"T"
    for q, t in ((query, target), (target, query), (query, matched[:3])):
        config = AlignConfig(mode, equalities=pairs)
        distance = bend_align(q, t, config, binary=dp_binary).require_distance()
        for threshold in (Unlimited(), *(MaxDistance(k) for k in
                                        sorted({0, max(0, distance - 1), distance, distance + 1}))):
            result = assert_distances(q, t, replace(config, threshold=threshold),
                                      bend_binary, dp_binary, cpp_binary, threads)
            assert result.edit_distance == (
                distance if isinstance(threshold, Unlimited) or distance <= threshold.value else -1)


@pytest.mark.parametrize("mode", list(Mode))
def test_all_byte_values_with_pairs(bend_binary, dp_binary, cpp_binary, mode):
    query = bytes(range(256))
    target = bytes(c ^ 128 for c in query)
    config = AlignConfig(mode, threshold=MaxDistance(0),
                         equalities=tuple(EqualityPair(c, c ^ 128) for c in range(128)))
    assert assert_distances(query, target, config, bend_binary, dp_binary, cpp_binary).edit_distance == 0


def test_many_duplicate_pairs(bend_binary, dp_binary, cpp_binary):
    config = AlignConfig(threshold=MaxDistance(0), equalities=(EqualityPair(0, 255),) * 2050)
    assert assert_distances(b"\0", b"\xff", config,
                            bend_binary, dp_binary, cpp_binary).edit_distance == 0


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", [Task.LOC, Task.PATH])
@pytest.mark.parametrize("format", list(CigarFormat))
def test_pairs_in_locations_and_traceback(bend_binary, cpp_binary, mode, task, format):
    pairs = WILDCARD_PAIRS + CASE_PAIRS + BYTE_PAIRS
    config = AlignConfig(mode, task, equalities=pairs, cigar_format=format)
    for query, target in ((b"aN\0\x80", b"AC\xff\x7f"), (b"A", b"C"),
                          (b"\0", b"\x80"), (b"aN", b"TTACAC")):
        actual = bend_align(query, target, config, binary=bend_binary)
        assert actual == cpp_edlib_align(query, target, config, binary=cpp_binary)
    result = bend_align(b"aN\0\x80", b"AC\xff\x7f", config, binary=bend_binary)
    assert result.require_distance() == 0
    if task == Task.PATH:
        assert result.alignment == (Operation.MATCH,) * 4
        assert result.cigar == ("4=" if format == CigarFormat.EXTENDED else "4M")


@settings(max_examples=80, deadline=None, derandomize=True)
@given(query=st.lists(st.sampled_from([0, 127, 128, 255, 65, 97, 67, 78]),
                     min_size=0, max_size=130).map(bytes),
       target=st.lists(st.sampled_from([0, 127, 128, 255, 65, 97, 67, 78]),
                      min_size=0, max_size=130).map(bytes),
       mode=st.sampled_from(list(Mode)),
       threshold=st.one_of(st.just(Unlimited()), st.integers(0, 130).map(MaxDistance)),
       pairs=st.lists(st.tuples(st.sampled_from([0, 127, 128, 255, 65, 97, 67, 78]),
                                st.sampled_from([0, 127, 128, 255, 65, 97, 67, 78])),
                      max_size=8))
def test_equality_differential(bend_binary, dp_binary, cpp_binary, query, target, mode, threshold, pairs):
    config = AlignConfig(mode, threshold=threshold, equalities=tuple(EqualityPair(*p) for p in pairs))
    assert_distances(query, target, config, bend_binary, dp_binary, cpp_binary)


def assert_masks(output, query, pairs):
    directed = {(a, b) for a, b in pairs} | {(b, a) for a, b in pairs}
    seen = set()
    for line in output.strip().splitlines():
        tag, block, code, direct, lookup = line.split(",")
        assert tag == "M"
        block, code, direct, lookup = map(int, (block, code, direct, lookup))
        assert (block, code) not in seen
        seen.add((block, code))
        word = query[block * 32:(block + 1) * 32]
        expected = sum(1 << bit for bit in range(32)
                       if bit >= len(word) or word[bit] == code or (word[bit], code) in directed)
        assert direct == lookup == expected, (block, code, direct, lookup, expected)
    assert seen == {(block, code) for block in range(max(1, (len(query) + 31) // 32))
                    for code in range(256)}


@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("query,pairs", [
    ("", "Aa"), ("aAN", "AaAN"), ("ACN" * 11, "NANC"),
    ("A" * 31 + "aC", "AaAaAaAA"),
])
def test_configured_profile_masks(myers_probe, threads, query, pairs):
    output = execute([myers_probe, *runtime_prefix(threads=threads), "masks-config", pairs, query]).stdout
    assert_masks(output, query.encode("ascii"), list(zip(pairs.encode("ascii")[::2],
                                                        pairs.encode("ascii")[1::2])))


def test_profile_masks_for_all_bytes(myers_probe):
    output = execute([myers_probe, *runtime_prefix(threads=4), "masks-byte-pairs"]).stdout
    assert_masks(output, bytes(range(256)), [(0, 255), (127, 128), (128, 255)])
