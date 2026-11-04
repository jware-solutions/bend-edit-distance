"""The project CC wrapper preserves executable paths, arguments and failures."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from bend_runtime import configure_toolchain

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("status", [0, 27])
def test_compiler_wrapper_arguments_and_status(tmp_path, status):
    compiler = tmp_path / "compiler with spaces"
    compiler.write_text(
        f"#!{sys.executable}\nimport json, sys\n"
        f"print(json.dumps(sys.argv[1:]))\nsys.exit({status})\n")
    compiler.chmod(0o755)
    arguments = ["-std=c2x", "source with spaces.c", "-o", "literal $() `name`"]
    result = subprocess.run([ROOT / "scripts/cc", *arguments],
        env={**os.environ, "BEND_CC": str(compiler)}, capture_output=True, text=True)
    assert result.returncode == status
    assert json.loads(result.stdout) == [
        "-mllvm", "-inline-threshold=1000", "-mllvm",
        "-inlinehint-threshold=2000", *arguments]
    assert result.stderr == ""


def test_explicit_invalid_compiler_is_rejected(monkeypatch, tmp_path):
    missing = str(tmp_path / "missing compiler")
    monkeypatch.setenv("CC", missing)
    with pytest.raises(RuntimeError, match="is not runnable"):
        configure_toolchain(ROOT)
    assert os.environ["CC"] == missing
