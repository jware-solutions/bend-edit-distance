"""NW distance portions of the pinned upstream Edlib regression suite."""

import json

import pytest

from tests.helpers import ROOT, compare_distances

CORPUS = json.loads((ROOT / "tests" / "regressions" / "upstream_nw.json").read_text())


@pytest.mark.parametrize("case", CORPUS["cases"], ids=lambda case: case["id"])
def test_upstream_nw_regression(bend_binary, dp_binary, cpp_binary, case):
    # Distances are saved independently of the C++ oracle invocation. Both
    # orientations exercise the Bend port's shorter-query selection.
    q, t = case["query"], case["target"]
    assert compare_distances(q, t, bend_binary, dp_binary, cpp_binary) == case["distance"]
    assert compare_distances(t, q, bend_binary, dp_binary, cpp_binary) == case["distance"]
