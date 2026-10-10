"""The verification gate must not silently fall back to an unpinned cache."""

import json
import sys

import pytest

from scripts.proof_kernel import record, require_kernel
from tests.helpers import ROOT, execute


@pytest.fixture
def toolchain(tmp_path):
    (tmp_path / ".bend-version").write_text("2.0.36\n")
    (tmp_path / ".lean-version").write_text("4.34.0\n")
    source = tmp_path / "build" / "tools" / "bend" / "bend2" / "bendtt.lean"
    source.parent.mkdir(parents=True)
    source.write_text("kernel source\n")
    kernel = tmp_path / "build" / "tools" / "kernel" / "bendtt"
    kernel.parent.mkdir(parents=True)
    kernel.write_text("#!/bin/sh\nexit 0\n")
    kernel.chmod(0o755)
    record(tmp_path)
    return tmp_path


def test_pinned_kernel_selected_even_with_external_override(toolchain, monkeypatch):
    monkeypatch.setenv("BENDTT", "/unrelated/user/cache/bendtt")
    assert require_kernel(toolchain) == toolchain / "build" / "tools" / "kernel" / "bendtt"


@pytest.mark.parametrize("path", [
    ".bend-version", ".lean-version", "build/tools/bend/bend2/bendtt.lean",
    "build/tools/kernel/bendtt",
])
def test_stale_or_changed_toolchain_is_rejected(toolchain, path):
    with (toolchain / path).open("a") as file:
        file.write("changed\n")
    with pytest.raises(RuntimeError, match="provenance"):
        require_kernel(toolchain)


@pytest.mark.parametrize("path", ["bendtt", "toolchain.json"])
def test_missing_kernel_or_provenance_is_rejected(toolchain, path):
    (toolchain / "build" / "tools" / "kernel" / path).unlink()
    with pytest.raises(RuntimeError, match="fresh pinned project kernel"):
        require_kernel(toolchain)


def test_nonexecutable_kernel_is_rejected(toolchain):
    (toolchain / "build" / "tools" / "kernel" / "bendtt").chmod(0o644)
    with pytest.raises(RuntimeError, match="not executable"):
        require_kernel(toolchain)


def test_invalid_provenance_is_rejected(toolchain):
    manifest = toolchain / "build" / "tools" / "kernel" / "toolchain.json"
    manifest.write_text("invalid json")
    with pytest.raises(RuntimeError, match="fresh pinned project kernel"):
        require_kernel(toolchain)
    manifest.write_text(json.dumps({"lean": "4.34.0"}))
    with pytest.raises(RuntimeError, match="provenance"):
        require_kernel(toolchain)


def test_runner_fails_before_pytest_when_kernel_is_missing(toolchain):
    # Exercise the actual entry point with an otherwise valid isolated checkout.
    (toolchain / "run_tests.py").write_bytes((ROOT / "run_tests.py").read_bytes())
    scripts = toolchain / "scripts"
    scripts.mkdir()
    (scripts / "proof_kernel.py").write_bytes((ROOT / "scripts" / "proof_kernel.py").read_bytes())
    (toolchain / "build" / "tools" / "kernel" / "bendtt").unlink()
    result = execute([sys.executable, toolchain / "run_tests.py", "--verdict"], check=False)
    assert result.returncode == 2
    assert "fresh pinned project kernel" in result.stderr
    assert "setup.sh" in result.stderr
