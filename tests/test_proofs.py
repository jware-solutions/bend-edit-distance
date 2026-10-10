import sys

import pytest

from tests.helpers import ROOT, execute


def test_bend_proofs(bend_tool):
    result = execute([bend_tool, ROOT / "PROOF.bend"], timeout=60)
    assert "ALL PROOFS CHECK" in result.stdout, result.stdout + result.stderr
    assert "SOME PROOFS FAIL" not in result.stdout + result.stderr


@pytest.mark.kernel
def test_bend_kernel_proofs(bend_tool, proof_kernel):
    result = execute([bend_tool, ROOT / "PROOF.bend", "--verdict"], timeout=300)
    assert "ALL PROOFS CHECK" in result.stdout, result.stdout + result.stderr
    assert "SOME PROOFS FAIL" not in result.stdout + result.stderr
    assert "Use --verdict" not in result.stdout + result.stderr


@pytest.mark.kernel
def test_kernel_failure_cannot_pass_verification(bend_tool, proof_kernel, tmp_path, monkeypatch):
    # An otherwise valid module lets this detect a missing/ignored --verdict,
    # independently of whether the ordinary checker rejects an invalid proof.
    source = tmp_path / "valid.bend"
    source.write_text("import Base\n\ndef value() -> Nat:\n  0n\n")
    marker = tmp_path / "kernel-invoked"
    rejecting_kernel = tmp_path / "rejecting-kernel"
    rejecting_kernel.write_text(
        f"#!{sys.executable}\nfrom pathlib import Path\n"
        f"Path({str(marker)!r}).touch()\nraise SystemExit(1)\n",
    )
    rejecting_kernel.chmod(0o755)
    monkeypatch.setenv("BENDTT", str(rejecting_kernel))
    result = execute([bend_tool, source, "--verdict"], timeout=60, check=False)
    assert marker.exists(), result.stdout + result.stderr
    assert result.returncode != 0, result.stdout + result.stderr
    assert "ALL PROOFS CHECK" not in result.stdout + result.stderr
