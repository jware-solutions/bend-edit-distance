import sys

import pytest

from tests.helpers import bend_align, bend_lengths, cpp_edlib_align, execute


def test_subprocess_failure_keeps_diagnostics():
    with pytest.raises(RuntimeError, match="Command exited 7") as error:
        execute([
            sys.executable, "-c",
            "import sys; print('output'); print('diagnostic', file=sys.stderr); sys.exit(7)",
        ])
    assert "output" in str(error.value)
    assert "diagnostic" in str(error.value)


def test_subprocess_timeout():
    with pytest.raises(RuntimeError, match="Timed out"):
        execute([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.1)


@pytest.mark.parametrize("helper", [bend_lengths, bend_align, cpp_edlib_align])
def test_nul_is_rejected_before_launch(helper):
    with pytest.raises(ValueError, match="NUL"):
        helper("A\0C", "T")


@pytest.mark.parametrize("helper", [bend_align, cpp_edlib_align])
def test_distance_rejects_non_ascii(helper):
    with pytest.raises(ValueError, match="ASCII"):
        helper("é", "e")


@pytest.mark.parametrize("helper,output", [
    (bend_lengths, "4,3,2"), (bend_lengths, "log\n4,3"),
    (bend_lengths, "-1,3"), (bend_lengths, ""),
    (bend_align, "4,3"), (bend_align, "-1"),
    (bend_align, "log\n1"), (bend_align, "1 2"), (bend_align, ""),
    (cpp_edlib_align, "log\n1"),
])
def test_malformed_native_output_fails(tmp_path, helper, output):
    binary = tmp_path / "bad-response"
    binary.write_text(f"#!{sys.executable}\nprint({output!r})\n")
    binary.chmod(0o755)
    with pytest.raises(ValueError, match="Expected"):
        helper("ACGT", "ACG", binary=binary)
