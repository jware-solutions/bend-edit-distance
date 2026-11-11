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


def compact_input(binary, query, pairs):
    import subprocess
    from transport import encode_request
    config = AlignConfig(equalities=tuple(EqualityPair(a, b) for a, b in pairs))
    process = subprocess.run([binary, *runtime_prefix(threads=1), "compact-input"],
                             input=encode_request(query, b"", config), capture_output=True, timeout=120)
    assert process.returncode == 0, process.stderr
    lines = [line for line in process.stdout.decode().splitlines() if line]
    assert len(lines) >= 2
    assert int(lines[0].split(",")[0]) == 2**32 - 1
    metadata = tuple(map(int, lines[1].split(",")[1:]))
    rows, stride, blocks, used, retained = metadata
    literals = set(query)
    relevant = literals | {b for a, b in pairs if a in literals} | {a for a, b in pairs if b in literals}
    admitted = literals | {x for pair in pairs for x in pair}
    assert len(relevant) <= rows <= len(admitted)
    capacity = 1 << max(0, rows - 1).bit_length()
    assert stride == 1 << max(0, blocks - 1).bit_length()
    assert blocks == (len(query) + 31) // 32
    assert used == len(query) % 32
    assert retained == 1024 + max(8, 4 * stride * capacity)
    relation = {(a, b) for a, b in pairs} | {(b, a) for a, b in pairs}
    seen = set()
    for line in lines[2:]:
        tag, block, code, actual = line.split(",")
        assert tag == "B"
        block, code, actual = map(int, (block, code, actual))
        assert (block, code) not in seen
        seen.add((block, code))
        word = query[block * 32:(block + 1) * 32]
        expected = 0 if block >= blocks else sum(1 << i for i in range(32)
            if i >= len(word) or word[i] == code or (word[i], code) in relation)
        assert actual == expected, (block, code, actual, expected)
    selected = range(blocks + 1) if blocks <= 129 else [*range(4), blocks - 2, blocks - 1, blocks]
    assert seen == {(b, c) for b in selected for c in range(256)}
    return metadata


@pytest.mark.parametrize("length", [0, *range(1, 34), 63, 64, 65, 95, 96, 97, 127, 128, 129, 4095, 4096, 4097])
def test_compact_binary_masks_and_clone(myers_probe, length):
    query = (b"A\0\xffA" * ((length + 3) // 4))[:length]
    pairs = [(65, 78), (78, 67), (0, 128), (128, 127), (255, 255), (65, 78), (78, 65), (9, 10)]
    compact_input(myers_probe, query, pairs)


@pytest.mark.parametrize("query", [b"A", b"AN", b"AC", b"ANC"])
def test_direct_matching_uses_original_literals_in_every_pair_order(myers_probe, query):
    import itertools
    pairs = [(65, 78), (78, 67), (67, 71)]
    outputs = [compact_input(myers_probe, query, list(order)) for order in itertools.permutations(pairs)]
    assert all(value == outputs[0] for value in outputs)


@pytest.mark.parametrize("alphabet", [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256])
def test_compact_row_capacity_boundaries(myers_probe, alphabet):
    query = bytes(range(alphabet)) * 2
    compact_input(myers_probe, query, [(a, a) for a in range(alphabet)])


@settings(max_examples=40, deadline=None, derandomize=True)
@given(query=st.binary(max_size=160), pairs=st.lists(st.tuples(st.integers(0, 255), st.integers(0, 255)), max_size=35))
def test_compact_masks_independent_predicate(myers_probe, query, pairs):
    compact_input(myers_probe, query, pairs)
    compact_input(myers_probe, query, pairs[::-1] + [(b, a) for a, b in pairs])


@pytest.mark.parametrize("length", [65535, 65536, 65537, 1048576])
def test_large_compact_profile_masks(myers_probe, length):
    compact_input(myers_probe, b"A" * length, [(65, 78), (78, 67), (0, 255)])


@pytest.mark.parametrize("pairs", [
    [(a, b) for a in range(256) for b in range(a + 1, 256)],
    [(65, 78), (78, 65)] * 32768,
    [(65, 65)] * 65536,
])
def test_maximum_preparation_graphs(myers_probe, pairs):
    compact_input(myers_probe, b"A\0\xffA" * 8 + b"A", pairs)


def test_bounded_exhaustive_direct_graph_masks(myers_probe):
    import itertools
    edges = [(65, 66), (66, 67), (65, 67)]
    queries = [bytes(q) for n in range(3) for q in itertools.product(b'ABC', repeat=n)]
    for subset in range(8):
        graph = [pair for bit, pair in enumerate(edges) if subset & (1 << bit)]
        for query in queries:
            compact_input(myers_probe, query, graph)
            # Force bitmap admission with reversed duplicates and reflexive
            # edges while the independent relation stays the same.
            repeated = (graph + [(b, a) for a, b in graph] + [(65, 65)]) * 16
            compact_input(myers_probe, query, repeated)


def test_compact_guards_ignore_poisoned_physical_capacity(myers_probe):
    output = execute([myers_probe, *runtime_prefix(threads=1), 'compact-guards']).stdout
    rows = [tuple(map(int, line.split(','))) for line in output.splitlines() if line]
    assert rows == [(3, 0, 0), (0, 3, 0), (0, 2, 2**32 - 1), (2**32 - 1, 2, 2**32 - 2)]
