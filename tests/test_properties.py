"""Shrinking, deterministic differential and metamorphic distance coverage."""

import pytest
from hypothesis import example, given, settings, strategies as st

from tests.test_alignment import compare_distances

# CLI transport excludes NUL, but includes controls, flags, punctuation and case.
ascii_text = st.text(alphabet=st.characters(min_codepoint=1, max_codepoint=127), max_size=96)


@settings(max_examples=20, deadline=None, derandomize=True, database=None)
@example(query="A" * 32, target="T" * 33)
@example(query="ACGT" * 16, target="AGT" * 21)
@given(query=ascii_text, target=ascii_text)
def test_fast_differential(bend_binary, dp_binary, cpp_binary, query, target):
    compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


@pytest.mark.alignment
@settings(max_examples=100, deadline=None, derandomize=True, database=None)
@given(query=ascii_text, target=ascii_text, third=ascii_text,
       threads=st.sampled_from([1, 2, 4]))
def test_distance_properties(bend_binary, dp_binary, cpp_binary, query, target, third, threads):
    def distance(left, right):
        return compare_distances(left, right, bend_binary, dp_binary, cpp_binary, threads=threads)

    forward = distance(query, target)
    assert abs(len(query) - len(target)) <= forward <= max(len(query), len(target))
    assert distance(target, query) == forward
    assert distance(query, query) == 0
    assert distance(query, "") == len(query)
    assert distance(query + "Z", target + "Z") == forward
    assert forward <= distance(query, third) + distance(third, target)
