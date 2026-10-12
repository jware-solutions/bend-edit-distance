"""Exact upstream CIGAR compatibility for explicitly selected traceback ties."""

import json

import pytest

from alignment import AlignConfig, AlignResult, CigarFormat, EqualityPair, Mode, Task
from tests.helpers import ROOT, assert_valid_path, bend_align, cpp_edlib_align

CORPUS = json.loads((ROOT / "tests" / "regressions" / "upstream_cigar.json").read_text())


@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("case", CORPUS["cases"], ids=lambda case: case["id"])
def test_exact_upstream_cigar_fixture(bend_binary, cpp_binary, threads, format, case):
    config = AlignConfig(Mode(case["mode"]), Task.PATH,
                         equalities=tuple(EqualityPair(*pair) for pair in case["equalities"]),
                         cigar_format=format)
    expected = AlignResult.from_edlib({**case["result"], "cigar": case["cigars"][format.value]})
    query, target = case["query"], case["target"]
    assert cpp_edlib_align(query, target, config, binary=cpp_binary) == expected
    actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
    assert actual == expected
    assert_valid_path(query, target, config, actual)
