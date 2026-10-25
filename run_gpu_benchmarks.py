"""Run strict GPU validation/benchmarks in Linux; forward Windows to WSL."""

from pathlib import Path
import os
import subprocess
import sys

from bend_runtime import configure_toolchain

ROOT = Path(__file__).resolve().parent


def main():
    if os.name == "nt":
        root = subprocess.check_output(["wsl.exe", "--exec", "wslpath", "-a", str(ROOT)], text=True, timeout=30).strip()
        return subprocess.call(["wsl.exe", "--cd", root, "--exec", "python3", f"{root}/run_gpu_benchmarks.py", *sys.argv[1:]])
    os.chdir(ROOT)
    configure_toolchain(ROOT)
    from benchmarks.gpu_runner import main as run
    return run()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"GPU validation failed: {error}", file=sys.stderr)
        raise SystemExit(2)
    except KeyboardInterrupt:
        raise SystemExit(130)
