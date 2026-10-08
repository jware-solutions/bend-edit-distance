import pytest

from tests.helpers import execute


@pytest.mark.parametrize("args", [[], ["ACGT"], ["A", "C", "G"]])
@pytest.mark.parametrize("implementation", ["bend_binary", "dp_binary"])
def test_wrong_argument_count(request, implementation, args):
    binary = request.getfixturevalue(implementation)
    result = execute([binary, "--threads", "1", "--", *args], check=False)
    assert result.returncode == 2
    assert result.stdout == ""
    assert "Expected QUERY TARGET" in result.stderr
