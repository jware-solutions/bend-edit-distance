import random
from itertools import product

import pytest

from tests.helpers import compare_distances, cpp_edlib_align

SMALL_SEQUENCES = tuple(
    "".join(chars) for size in range(5) for chars in product("ACG", repeat=size)
)

# These cases independently check both Bend algorithms and the C++ oracle.
KNOWN_DISTANCES = [
    ("", "", 0), ("", "ACGT", 4), ("ACGT", "", 4),
    ("ACGT", "ACGT", 0), ("A", "T", 1), ("ACGT", "AGT", 1),
    ("AGT", "ACGT", 1), ("AAAA", "TTTT", 4),
    ("kitten", "sitting", 3), ("ACT", "CGACTGAC", 5),
    ("--threads", "--threads", 0), ("A C\n", "AC\n", 1),
]


@pytest.mark.parametrize("query,target,expected", KNOWN_DISTANCES)
def test_cpp_oracle(cpp_binary, query, target, expected):
    assert cpp_edlib_align(query, target, binary=cpp_binary) == expected


@pytest.mark.parametrize("query,target,expected", KNOWN_DISTANCES)
def test_distance_matches_cpp(bend_binary, dp_binary, cpp_binary, query, target, expected):
    assert compare_distances(query, target, bend_binary, dp_binary, cpp_binary) == expected


@pytest.mark.alignment
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 95, 96, 97,
                                   127, 128, 129, 255, 256, 257])
def test_word_boundaries(bend_binary, dp_binary, cpp_binary, length):
    query = ("ACGT" * 65)[:length]
    target = query[:length // 2] + "N" + query[length // 2 + 1:] + "A"
    compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
def test_seeded_random_distances(bend_binary, dp_binary, cpp_binary):
    rng = random.Random(20261008)
    for _ in range(100):
        query = "".join(rng.choices("ACGT", k=rng.randrange(81)))
        target = "".join(rng.choices("ACGT", k=rng.randrange(81)))
        compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
@pytest.mark.parametrize("threads", [1, 2, 4])
def test_distance_with_multiple_threads(bend_binary, dp_binary, cpp_binary, threads):
    query, target = "ACGT" * 32, "AGT" * 32
    compare_distances(query, target, bend_binary, dp_binary, cpp_binary, threads=threads)


@pytest.mark.alignment
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 127, 128, 129, 257])
def test_block_carries_and_large_distances(bend_binary, dp_binary, cpp_binary, length):
    # Exercise positive and negative carries across entire words, including
    # distances above the original Edlib dynamic thresholds of 32/64/128.
    cases = [
        ("A" * length, "T" * length),
        ("A" * length, "A" * (2 * length + 1)),
        ("A" * length + "C" * length, "C" * length + "A" * length),
    ]
    for query, target in cases:
        compare_distances(query, target, bend_binary, dp_binary, cpp_binary)
        compare_distances(target, query, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
def test_every_padding_size(bend_binary, dp_binary, cpp_binary):
    for padding in range(32):
        query = ("ACGT" * 24)[:96 - padding]
        target = "T" * 21 + query[13:] + "AG" * 19
        compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
def test_seeded_long_ascii_distances(bend_binary, dp_binary, cpp_binary):
    rng = random.Random(20261009)
    alphabet = "".join(chr(code) for code in range(1, 128))
    for query_length, target_length in [(257, 255), (511, 513), (1024, 1024)]:
        query = "".join(rng.choices(alphabet, k=query_length))
        target = "".join(rng.choices(alphabet, k=target_length))
        for threads in (1, 2, 4):
            compare_distances(query, target, bend_binary, dp_binary, cpp_binary, threads=threads)


@pytest.mark.parametrize("query,target,expected", [
    ("AB", "BA", 2),  # Transposition is two edits in Levenshtein distance.
    ("ABABAB", "BABABA", 2),
    ("GATTACA", "GCATGCU", 4),
    ("A", "T" * 4096, 4096),
    ("ACG", "ACGT" * 1024, 4093),
])
def test_dp_recurrence_and_shorter_rows(bend_binary, dp_binary, cpp_binary,
                                      query, target, expected):
    # Both argument orders must orient the DP rows along the short sequence.
    assert compare_distances(query, target, bend_binary, dp_binary, cpp_binary) == expected
    assert compare_distances(target, query, bend_binary, dp_binary, cpp_binary) == expected


@pytest.mark.alignment
@pytest.mark.parametrize("query", SMALL_SEQUENCES, ids=repr)
def test_exhaustive_small_inputs(bend_binary, dp_binary, cpp_binary, query):
    # 1 + 3 + 9 + 27 + 81 = 121 strings; all 121**2 = 14,641 ordered
    # pairs, including empty inputs and both orientations. Do not deduplicate.
    assert len(SMALL_SEQUENCES) == 121
    for target in SMALL_SEQUENCES:
        compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
@pytest.mark.parametrize("length", range(1, 33))
def test_every_single_word_length(bend_binary, dp_binary, cpp_binary, length):
    query = ("ACG" * 11)[:length]
    cases = [(query, 0), ("T" * length, length), ("", length)]
    # Every real bit can be the site of each edit, including the high bit at 32.
    for position in range(length):
        cases.extend([
            (query[:position] + "T" + query[position + 1:], 1),
            (query[:position] + query[position + 1:], 1),
            (query[:position] + "T" + query[position:], 1),
        ])
    cases.append((query + "T", 1))
    for target, expected in cases:
        assert compare_distances(query, target, bend_binary, dp_binary, cpp_binary) == expected
        assert compare_distances(target, query, bend_binary, dp_binary, cpp_binary) == expected


@pytest.mark.parametrize("query,target,expected", [
    pytest.param("a", "A", 1, id="case-single"),
    pytest.param("acgt" * 33, "ACGT" * 33, 132, id="case-multiblock"),
    pytest.param("AaCcGgTt", "AACCGGTT", 4, id="mixed-case"),
    pytest.param("N", "A", 1, id="ordinary-equality-no-wildcard"),
    pytest.param("AC" * 64, "CA" * 64, 2, id="alternating-phase"),
    pytest.param("ACG" * 43, "CGA" * 43, 2, id="triplet-phase"),
    pytest.param("A" * 129, "A" * 64 + "C" + "A" * 64, 1, id="homopolymer"),
    pytest.param("ACGT" * 32, "ACGT" * 16 + "ACGT" * 15, 4, id="motif-deletion"),
    pytest.param("A", "C" * 4095 + "A", 4095, id="imbalanced-last-match"),
    pytest.param("AC", "C" * 4096, 4095, id="imbalanced-one-match"),
    pytest.param("ACG", "T" * 4096, 4096, id="imbalanced-disjoint"),
    pytest.param("ACG", "T" * 2046 + "ACG" + "T" * 2047, 4093, id="imbalanced-internal-match"),
])
def test_distance_regressions(bend_binary, dp_binary, cpp_binary, query, target, expected):
    for threads in (1, 2):
        assert compare_distances(query, target, bend_binary, dp_binary, cpp_binary,
                                 threads=threads) == expected
        assert compare_distances(target, query, bend_binary, dp_binary, cpp_binary,
                                 threads=threads) == expected
