"""Persistent byte alignment adapters and legacy CLI test utilities."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
from typing import Sequence

from alignment import AlignConfig, AlignResult
from transport import cached_worker, sequence_bytes

ROOT = Path(__file__).resolve().parents[1]
BEND_BINARY = ROOT / "build" / "bend-edlib"
DP_BINARY = ROOT / "build" / "bend-distance-dp"
CPP_BINARY = ROOT / "build" / "edlib-oracle"
MAX_SEQUENCE_LENGTH = 4096


def execute(
    command: Sequence[str | Path], *, timeout: float = 10, check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run literal argv and retain both streams in actionable failure messages."""
    argv = [str(arg) for arg in command]
    try:
        result = subprocess.run(
            argv, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
            timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Timed out after {timeout}s: {argv!r}") from error
    except OSError as error:
        raise RuntimeError(f"Could not run {argv!r}: {error}") from error
    if check and result.returncode:
        raise RuntimeError(
            f"Command exited {result.returncode}: {argv!r}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def _validate_sequences(query: str, target: str) -> None:
    for sequence in (query, target):
        if not isinstance(sequence, str):
            raise TypeError("Sequences must be strings")
        if "\0" in sequence:
            raise ValueError("CLI sequences cannot contain NUL; use a binary worker")
        if len(sequence) > MAX_SEQUENCE_LENGTH:
            raise ValueError(
                f"Sequence length exceeds maximum of {MAX_SEQUENCE_LENGTH} characters per sequence"
            )


def bend_output(
    query: str, target: str, *, binary: Path = BEND_BINARY,
    timeout: float = 10, threads: int = 1,
) -> str:
    _validate_sequences(query, target)
    if threads < 1:
        raise ValueError("threads must be positive")
    # -- preserves empty strings and sequences that look like runtime flags.
    return execute([
        binary, "--threads", str(threads), "--", query, target,
    ], timeout=timeout).stdout.strip()


def bend_lengths(
    query: str, target: str, *, binary: Path = BEND_BINARY,
    timeout: float = 10, threads: int = 1,
) -> tuple[int, int]:
    output = bend_output(query, target, binary=binary, timeout=timeout, threads=threads)
    match = re.fullmatch(r"([0-9]+),([0-9]+)", output)
    if match is None:
        raise ValueError(f"Expected QUERY_LENGTH,TARGET_LENGTH, got {output!r}")
    return int(match[1]), int(match[2])


def bend_distance(
    query: bytes | str, target: bytes | str, *, binary: Path = BEND_BINARY,
    timeout: float = 10, threads: int = 1,
) -> int:
    return bend_align(query, target, binary=binary, timeout=timeout,
                      threads=threads).require_distance()


def cpp_edlib_distance(
    query: bytes | str, target: bytes | str, *, binary: Path = CPP_BINARY, timeout: float = 10,
) -> int:
    return cpp_edlib_align(query, target, binary=binary, timeout=timeout).require_distance()


def bend_align(
    query: bytes | str, target: bytes | str, config: AlignConfig = AlignConfig(), *,
    binary: Path = BEND_BINARY, timeout: float = 10, threads: int = 1,
) -> AlignResult:
    query, target = sequence_bytes(query), sequence_bytes(target)
    if not isinstance(config, AlignConfig):
        raise TypeError("Expected AlignConfig")
    if type(threads) is not int or threads < 1:
        raise ValueError("threads must be positive")
    worker = cached_worker([binary, "--threads", str(threads), "--", "--worker"], cwd=ROOT)
    return worker.align(query, target, config, timeout=timeout)


def cpp_edlib_align(
    query: bytes | str, target: bytes | str, config: AlignConfig = AlignConfig(), *,
    binary: Path = CPP_BINARY, timeout: float = 10,
) -> AlignResult:
    query, target = sequence_bytes(query), sequence_bytes(target)
    if not isinstance(config, AlignConfig):
        raise TypeError("Expected AlignConfig")
    return cached_worker([binary, "--worker"], cwd=ROOT).align(query, target, config, timeout=timeout)


def bend_dp_distance(
    query: bytes | str, target: bytes | str, *, binary: Path = DP_BINARY,
    timeout: float = 10, threads: int = 1,
) -> int:
    """Call the independent two-row DP executable, with the same protocol."""
    return bend_distance(query, target, binary=binary, timeout=timeout, threads=threads)


def compare_distances(query, target, bend_binary, dp_binary, cpp_binary, *, threads=1):
    """Unrestricted NW, unit costs, ordinary equality; identical ordered inputs."""
    distances = {
        "dp": bend_dp_distance(query, target, binary=dp_binary, threads=threads),
        "myers": bend_distance(query, target, binary=bend_binary, threads=threads),
        "cpp_edlib": cpp_edlib_distance(query, target, binary=cpp_binary),
    }
    assert len(set(distances.values())) == 1, (
        f"query={query!r}, target={target!r}, threads={threads}, {distances=}"
    )
    return distances["cpp_edlib"]
