from bend_runtime import runtime_prefix
import pytest

from tests.helpers import MAX_SEQUENCE_LENGTH, cpp_edlib_distance, execute


@pytest.fixture(params=["bend_binary", "dp_binary"])
def distance_binary(request):
    return request.getfixturevalue(request.param)


def invoke(binary, query, target, threads):
    # Call the native boundary directly: adapters must not mask rejections.
    return execute(
        [binary, *runtime_prefix(threads=threads), query, target], check=False,
    )


@pytest.mark.parametrize("threads", [1, 2])
@pytest.mark.parametrize("reverse", [False, True])
@pytest.mark.parametrize("length", [MAX_SEQUENCE_LENGTH - 1, MAX_SEQUENCE_LENGTH])
@pytest.mark.parametrize("other", ["", "A", "A" * MAX_SEQUENCE_LENGTH, "T" * MAX_SEQUENCE_LENGTH])
def test_native_accepts_length_boundary(distance_binary, threads, reverse, length, other):
    query, target = "A" * length, other
    if reverse:
        query, target = target, query
    expected = max(len(query), len(target)) if "T" in other else abs(len(query) - len(target))
    result = invoke(distance_binary, query, target, threads)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"
    assert result.stderr == ""


@pytest.mark.parametrize("threads", [1, 2])
def test_native_accepts_all_non_nul_ascii(distance_binary, cpp_binary, threads):
    query = "".join(chr(code) for code in range(1, 128))
    target = query[::-1]
    expected = cpp_edlib_distance(query, target, binary=cpp_binary)
    result = invoke(distance_binary, query, target, threads)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"
    assert result.stderr == ""
