import pytest

from tests.helpers import execute


@pytest.mark.parametrize("args", [[], ["ACGT"], ["A", "C", "G"]])
def test_wrong_argument_count(bend_binary, args):
    result = execute([bend_binary, "--threads", "1", "--", *args], check=False)
    assert result.returncode == 2
    assert result.stdout == ""
    assert "Expected QUERY TARGET" in result.stderr
