"""Arguments for native Bend 2.0.38+ executables (not the Bend driver)."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import re


def runtime_prefix(*, threads: int | None = None, gpu: str | None = None,
                   gpu_build: bool = False) -> list[str]:
    """Protect every application argument, including literal RTS delimiters."""
    options = []
    if threads is not None:
        if type(threads) is not int or threads < 1:
            raise ValueError("threads must be a positive integer")
        options += ["--threads", str(threads)]
    if gpu is not None:
        options += ["--gpu", gpu]
    if gpu_build:
        options += ["--gpu-build"]
    return ["+RTS", *options, "-RTS", "--RTS"]


def reproducible_env() -> dict[str, str]:
    """Keep user runtime defaults out of tests and benchmark subprocesses."""
    return {**os.environ, "BENDRTS": "", "BEND_NO_TELEMETRY": "1"}


def configure_toolchain(root: Path) -> None:
    """Use the project compiler and reject stale installs before running work."""
    compiler = root / "build/tools/bend/bin/bend"
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        raise RuntimeError("Pinned project Bend is missing; run bash scripts/setup.sh")
    os.environ["PATH"] = str(root / "build/tools/bend/bin") + os.pathsep + os.environ.get("PATH", "")
    os.environ["BENDRTS"] = ""
    os.environ["BEND_NO_TELEMETRY"] = "1"
    # Preserve and validate an explicit compiler selection.
    if "CC" not in os.environ and shutil.which("clang-19"):
        os.environ["CC"] = "clang-19"
    require_clang(os.environ.get("CC", "clang"))
    version = subprocess.check_output([str(compiler), "version"], text=True).strip()
    expected = "bend " + (root / ".bend-version").read_text().strip()
    if version != expected:
        raise RuntimeError(f"Expected {expected}, found {version}; run bash scripts/setup.sh")


def require_clang(cc: str, minimum: int = 14) -> str:
    """Require a working Clang executable of the requested minimum version."""
    try:
        result = subprocess.run([cc, "--version"], capture_output=True, text=True, timeout=30)
    except OSError as error:
        raise RuntimeError(f"CC={cc!r} is not runnable: {error}") from error
    match = re.search(r"^(?:Apple )?(?:\w+ )?clang version (\d+)", result.stdout, re.M)
    if result.returncode or not match or int(match[1]) < minimum:
        raise RuntimeError(f"CC={cc!r} must be a usable Clang {minimum}+: {result.stdout.strip()}")
    return result.stdout.splitlines()[0]
