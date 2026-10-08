import pytest

from tests.helpers import bend_lengths

pytestmark = pytest.mark.smoke


@pytest.mark.parametrize("query,target", [
    ("ACGT", "ACG"), ("", ""), ("", "ACGT"), ("ACGT", ""),
    ("A", "T"), ("A" * 129, "C" * 65), ("A C", "T\tG\n"),
    ("--threads", "--gpu"), ("--help", "--bend-help"),
    ("';$(echo x)", '"\\*'),
])
def test_python_bend_integration(bend_binary, query, target):
    assert bend_lengths(query, target, binary=bend_binary) == (len(query), len(target))


def test_native_cpu_threads(bend_binary):
    assert bend_lengths("ACGT", "ACG", binary=bend_binary, threads=2) == (4, 3)
