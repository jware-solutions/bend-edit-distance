import random

import pytest

from tests.helpers import bend_align, cpp_edlib_align

# These cases independently check the C++ oracle and Bend implementation.
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


@pytest.mark.alignment
@pytest.mark.parametrize("query,target,expected", KNOWN_DISTANCES)
def test_distance_matches_cpp(bend_binary, cpp_binary, query, target, expected):
    reference = cpp_edlib_align(query, target, binary=cpp_binary)
    assert reference == expected
    assert bend_align(query, target, binary=bend_binary) == reference


@pytest.mark.alignment
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 95, 96, 97,
                                   127, 128, 129, 255, 256, 257])
def test_word_boundaries(bend_binary, cpp_binary, length):
    query = ("ACGT" * 65)[:length]
    target = query[:length // 2] + "N" + query[length // 2 + 1:] + "A"
    assert bend_align(query, target, binary=bend_binary) == cpp_edlib_align(
        query, target, binary=cpp_binary,
    )


@pytest.mark.alignment
def test_seeded_random_distances(bend_binary, cpp_binary):
    rng = random.Random(20261008)
    for index in range(100):
        query = "".join(rng.choices("ACGT", k=rng.randrange(81)))
        target = "".join(rng.choices("ACGT", k=rng.randrange(81)))
        actual = bend_align(query, target, binary=bend_binary)
        expected = cpp_edlib_align(query, target, binary=cpp_binary)
        assert actual == expected, f"case={index}, query={query!r}, target={target!r}"


@pytest.mark.alignment
def test_distance_with_multiple_threads(bend_binary, cpp_binary):
    query, target = "ACGT" * 32, "AGT" * 32
    assert bend_align(query, target, binary=bend_binary, threads=2) == cpp_edlib_align(
        query, target, binary=cpp_binary,
    )


@pytest.mark.alignment
@pytest.mark.parametrize("length", [31, 32, 33, 63, 64, 65, 127, 128, 129, 257])
def test_block_carries_and_large_distances(bend_binary, cpp_binary, length):
    # Exercise positive and negative carries across entire words, including
    # distances above the original Edlib dynamic thresholds of 32/64/128.
    cases = [
        ("A" * length, "T" * length),
        ("A" * length, "A" * (2 * length + 1)),
        ("A" * length + "C" * length, "C" * length + "A" * length),
    ]
    for query, target in cases:
        expected = cpp_edlib_align(query, target, binary=cpp_binary)
        assert bend_align(query, target, binary=bend_binary) == expected
        assert bend_align(target, query, binary=bend_binary) == expected


@pytest.mark.alignment
def test_every_padding_size(bend_binary, cpp_binary):
    for padding in range(32):
        query = ("ACGT" * 24)[:96 - padding]
        target = "T" * 21 + query[13:] + "AG" * 19
        assert bend_align(query, target, binary=bend_binary) == cpp_edlib_align(
            query, target, binary=cpp_binary,
        ), f"padding={padding}"


@pytest.mark.alignment
def test_seeded_long_ascii_distances(bend_binary, cpp_binary):
    rng = random.Random(20261009)
    alphabet = "".join(chr(code) for code in range(1, 128))
    for query_length, target_length in [(257, 255), (511, 513), (1024, 1024)]:
        query = "".join(rng.choices(alphabet, k=query_length))
        target = "".join(rng.choices(alphabet, k=target_length))
        expected = cpp_edlib_align(query, target, binary=cpp_binary)
        for threads in (1, 2, 4):
            assert bend_align(query, target, binary=bend_binary, threads=threads) == expected
