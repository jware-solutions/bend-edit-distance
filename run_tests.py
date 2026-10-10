"""Run the native Bend pytest suite, forwarding Windows invocations to WSL."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys

from scripts.proof_kernel import require_kernel

ROOT = Path(__file__).resolve().parent
TEST_PYTHON = ROOT / "build" / "test-venv" / "bin" / "python"


def main() -> int:
    args = sys.argv[1:]
    if os.name == "nt":
        # wslpath handles drive mappings and spaces; no shell or quoting layer.
        result = subprocess.run(
            ["wsl.exe", "--exec", "wslpath", "-a", str(ROOT)],
            capture_output=True, text=True, check=True, timeout=30,
        )
        root = result.stdout.strip()
        return subprocess.call([
            "wsl.exe", "--cd", root, "--exec", "python3",
            f"{root}/run_tests.py", *args,
        ])

    os.chdir(ROOT)
    if "--setup" in args:
        args.remove("--setup")
        subprocess.run([
            "bash", str(ROOT / "scripts" / "setup.sh"),
        ], check=True)

    # Prefer the downloaded compiler and explicitly built proof kernel.
    tools = ROOT / "build" / "tools"
    os.environ["PATH"] = os.pathsep.join([
        str(tools / "bend" / "bin"), os.environ.get("PATH", ""),
    ])
    os.environ["BEND_NO_TELEMETRY"] = "1"
    if "--verdict" in args:
        os.environ["BENDTT"] = str(require_kernel(ROOT))

    # Prefer the project environment without requiring shell activation.
    if TEST_PYTHON.exists() and Path(sys.prefix) != TEST_PYTHON.parents[1]:
        return subprocess.call([str(TEST_PYTHON), str(ROOT / "run_tests.py"), *args])
    if importlib.util.find_spec("pytest") is None:
        print("pytest is missing. Run: python run_tests.py --setup", file=sys.stderr)
        return 2

    import pytest

    return int(pytest.main(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Test runner failed: {error}", file=sys.stderr)
        raise SystemExit(2)
    except KeyboardInterrupt:
        raise SystemExit(130)
