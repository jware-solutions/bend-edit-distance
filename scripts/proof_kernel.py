"""Record and validate the project kernel built by scripts/setup.sh."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys


def fingerprint(root: Path) -> dict[str, str]:
    tools = root / "build" / "tools"
    source = (tools / "bend" / "bend2" / "bendtt.lean").read_bytes()
    compiled_source = (tools / "kernel" / "bendtt.lean").read_bytes()
    if source != compiled_source:
        raise ValueError("kernel provenance: compiled source differs from pinned Bend source")
    return {
        "bend": (root / ".bend-version").read_text().strip(),
        "lean": (root / ".lean-version").read_text().strip(),
        "source_sha256": hashlib.sha256(
            source,
        ).hexdigest(),
        "compiled_source_sha256": hashlib.sha256(compiled_source).hexdigest(),
        "kernel_sha256": hashlib.sha256(
            (tools / "kernel" / "bendtt").read_bytes(),
        ).hexdigest(),
    }


def record(root: Path) -> None:
    manifest = root / "build" / "tools" / "kernel" / "toolchain.json"
    manifest.write_text(json.dumps(fingerprint(root), indent=2) + "\n")


def require_kernel(root: Path) -> Path:
    """Reject missing, stale or changed kernels instead of using a user cache."""
    kernel = root / "build" / "tools" / "kernel" / "bendtt"
    manifest = kernel.with_name("toolchain.json")
    try:
        if not os.access(kernel, os.X_OK):
            raise ValueError("project kernel is missing or not executable")
        if json.loads(manifest.read_text()) != fingerprint(root):
            raise ValueError("kernel provenance does not match the pinned toolchain")
    except (OSError, ValueError) as error:
        raise RuntimeError(
            f"Kernel verification requires a fresh pinned project kernel: {error}. "
            "Run: bash scripts/setup.sh (in WSL on Windows).",
        ) from error
    return kernel


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    if sys.argv[1:] != ["--record"]:
        raise SystemExit("Usage: python3 scripts/proof_kernel.py --record")
    record(root)
