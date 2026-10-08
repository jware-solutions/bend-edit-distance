import pytest

from tests.helpers import MAX_SEQUENCE_LENGTH, cpp_edlib_align, execute


@pytest.fixture(params=["bend_binary", "dp_binary"])
def distance_binary(request):
    return request.getfixturevalue(request.param)


def invoke(binary, query, target, threads):
    # Call the native boundary directly: adapters must not mask rejections.
    return execute(
        [binary, "--threads", str(threads), "--", query, target], check=False,
    )


@pytest.mark.parametrize("args", [[], ["ACGT"], ["A", "C", "G"]])
@pytest.mark.parametrize("implementation", ["bend_binary", "dp_binary"])
def test_wrong_argument_count(request, implementation, args):
    binary = request.getfixturevalue(implementation)
    result = execute([binary, "--threads", "1", "--", *args], check=False)
    assert result.returncode == 2
    assert result.stdout == ""
    assert "Expected QUERY TARGET" in result.stderr


@pytest.mark.parametrize("threads", [1, 2])
@pytest.mark.parametrize("character", ["\x80", "é", "ÿ", "Ā", "Ł", "😀"])
@pytest.mark.parametrize("placement", ["both", "query", "target", "empty_query", "empty_target"])
def test_native_rejects_non_ascii(distance_binary, threads, character, placement):
    pairs = {
        "both": (character, character),  # Original Ā/Ā regression.
        "query": ("AC" + character, "AC"),
        "target": ("AC", "AC" + character),
        "empty_query": ("", character),
        "empty_target": (character, ""),
    }
    result = invoke(distance_binary, *pairs[placement], threads)
    assert result.returncode == 2
    assert result.stdout == ""
    assert "ASCII" in result.stderr


@pytest.mark.parametrize("threads", [1, 2])
@pytest.mark.parametrize("reverse", [False, True])
@pytest.mark.parametrize("other", ["", "A", "A" * MAX_SEQUENCE_LENGTH])
def test_native_rejects_overlong_sequences(distance_binary, threads, reverse, other):
    pair = ("A" * (MAX_SEQUENCE_LENGTH + 1), other)
    if reverse:
        pair = pair[::-1]
    result = invoke(distance_binary, *pair, threads)
    assert result.returncode == 2
    assert result.stdout == ""
    assert f"maximum of {MAX_SEQUENCE_LENGTH}" in result.stderr


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
    expected = cpp_edlib_align(query, target, binary=cpp_binary)
    result = invoke(distance_binary, query, target, threads)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"
    assert result.stderr == ""


@pytest.mark.parametrize("reverse", [False, True])
def test_native_checks_last_allowed_character(distance_binary, reverse):
    pair = ("A" * (MAX_SEQUENCE_LENGTH - 1) + "Ā", "A")
    if reverse:
        pair = pair[::-1]
    result = invoke(distance_binary, *pair, 1)
    assert result.returncode == 2
    assert result.stdout == ""
    assert "ASCII" in result.stderr
