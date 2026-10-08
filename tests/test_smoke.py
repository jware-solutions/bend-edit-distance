import pytest

from tests.helpers import bend_align, cpp_edlib_align


@pytest.mark.parametrize("query,target", [
    ("ACGT", "ACG"), ("", ""), ("", "ACGT"), ("ACGT", ""),
    ("A", "T"), ("A" * 129, "C" * 65), ("A C", "T\tG\n"),
    ("--threads", "--gpu"), ("--help", "--bend-help"),
    ("';$(echo x)", '"\\*'),
])
def test_python_bend_integration(bend_binary, cpp_binary, query, target):
    assert bend_align(query, target, binary=bend_binary) == cpp_edlib_align(
        query, target, binary=cpp_binary,
    )


def test_native_cpu_threads(bend_binary):
    assert bend_align("ACGT", "ACG", binary=bend_binary, threads=2) == 1
