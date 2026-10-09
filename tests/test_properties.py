"""Metric laws apply ONLY to unrestricted NW with ordinary character equality.

Do not reuse these properties for HW/SHW, threshold sentinel results or custom
equalities. The latter need not even be transitive. All inputs here are in the
supported CLI domain. Hypothesis keeps replay/generate/shrink phases enabled.
"""

import json

from hypothesis import example, given, strategies as st
import pytest

from tests.helpers import ROOT, bend_align, bend_dp_align, compare_distances, cpp_edlib_align

SAVED = json.loads((ROOT / "tests" / "regressions" / "nw.json").read_text())
pytestmark = pytest.mark.alignment
ASCII = "".join(chr(code) for code in range(1, 128))
BOUNDARIES = (0, 1, 2, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257)


@st.composite
def boundary_sequences(draw):
    length = draw(st.sampled_from(BOUNDARIES))
    return draw(st.text(alphabet="ACGTacgt", min_size=length, max_size=length))


SEQUENCES = st.one_of(
    st.text(alphabet="ACGTacgt", max_size=160),
    st.text(alphabet=ASCII, max_size=96),
    boundary_sequences(),
    st.builds(lambda motif, count: motif * count,
              st.text(alphabet="ACGTacgt", min_size=1, max_size=4), st.integers(0, 65)),
)


def saved_examples(test):
    # Portable, reviewable examples run even with a fresh Hypothesis database.
    # These are seeded known regressions, not claimed as newly discovered bugs.
    for case in reversed(SAVED):
        test = example(query=case["query"], target=case["target"])(test)
    return test


@pytest.mark.parametrize("case", SAVED, ids=lambda case: case["id"])
def test_saved_regressions(bend_binary, dp_binary, cpp_binary, case):
    assert compare_distances(case["query"], case["target"], bend_binary,
                             dp_binary, cpp_binary) == case["distance"]


@given(query=SEQUENCES, target=SEQUENCES)
@saved_examples
def test_nw_differential(bend_binary, dp_binary, cpp_binary, query, target):
    compare_distances(query, target, bend_binary, dp_binary, cpp_binary)


IMPLEMENTATIONS = [
    ("bend_binary", bend_align), ("dp_binary", bend_dp_align), ("cpp_binary", cpp_edlib_align),
]


@pytest.mark.parametrize("fixture,align", IMPLEMENTATIONS, ids=["myers", "dp", "edlib"])
@given(query=SEQUENCES, target=SEQUENCES)
@saved_examples
def test_unrestricted_nw_identity_symmetry_bounds(request, fixture, align, query, target):
    binary = request.getfixturevalue(fixture)
    distance = align(query, target, binary=binary)
    assert align(query, query, binary=binary) == 0
    assert (distance == 0) == (query == target)
    assert distance == align(target, query, binary=binary)
    assert abs(len(query) - len(target)) <= distance <= max(len(query), len(target))


@pytest.mark.parametrize("fixture,align", IMPLEMENTATIONS, ids=["myers", "dp", "edlib"])
@given(a=SEQUENCES, b=SEQUENCES, c=SEQUENCES)
@example(a="", b="A", c="AA")
@example(a="a", b="A", c="aA")
@example(a="AC" * 16, b="CA" * 16, c="AC" * 17)
def test_unrestricted_nw_triangle_inequality(request, fixture, align, a, b, c):
    binary = request.getfixturevalue(fixture)
    ab = align(a, b, binary=binary)
    bc = align(b, c, binary=binary)
    ac = align(a, c, binary=binary)
    assert ac <= ab + bc, f"{a=}, {b=}, {c=}, {ab=}, {bc=}, {ac=}"
