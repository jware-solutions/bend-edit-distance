"""Run strict GPU validation/benchmarks in Linux; forward Windows to WSL."""

from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def main():
    if os.name == "nt":
        root = subprocess.check_output(["wsl.exe", "--exec", "wslpath", "-a", str(ROOT)], text=True, timeout=30).strip()
        return subprocess.call(["wsl.exe", "--cd", root, "--exec", "python3", f"{root}/run_gpu_benchmarks.py", *sys.argv[1:]])
    os.chdir(ROOT)
    os.environ["PATH"] = str(ROOT / "build/tools/bend/bin") + os.pathsep + os.environ.get("PATH", "")
    os.environ["BEND_NO_TELEMETRY"] = "1"
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
