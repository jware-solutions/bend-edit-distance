import pytest

from tests.helpers import ROOT, execute


def test_bend_proofs(bend_tool):
    result = execute([bend_tool, ROOT / "PROOF.bend"], timeout=60)
    assert "ALL PROOFS CHECK" in result.stdout, result.stdout + result.stderr
    assert "SOME PROOFS FAIL" not in result.stdout + result.stderr


@pytest.mark.kernel
def test_bend_kernel_proofs(bend_tool):
    result = execute([bend_tool, ROOT / "PROOF.bend", "--verdict"], timeout=300)
    assert "ALL PROOFS CHECK" in result.stdout, result.stdout + result.stderr
    assert "SOME PROOFS FAIL" not in result.stdout + result.stderr
