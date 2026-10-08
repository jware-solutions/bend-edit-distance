import random

import pytest

from tests.helpers import bend_align, cpp_edlib_align

# These cases also exercise the C++ oracle before Bend alignment exists.
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
@pytest.mark.parametrize("length", [63, 64, 65, 127, 128, 129])
def test_word_boundaries(bend_binary, cpp_binary, length):
    query = ("ACGT" * 33)[:length]
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
