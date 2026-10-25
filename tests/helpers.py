"""Persistent byte alignment adapters and legacy CLI test utilities."""

from __future__ import annotations

from bend_runtime import runtime_prefix, reproducible_env

from pathlib import Path
import re
import subprocess
from typing import Sequence

from alignment import AlignConfig, AlignResult, CigarFormat, Operation, Task
from transport import cached_worker, sequence_bytes

ROOT = Path(__file__).resolve().parents[1]
BEND_BINARY = ROOT / "build" / "bend-edit-distance"
DP_BINARY = ROOT / "build" / "bend-distance-dp"
CPP_BINARY = ROOT / "build" / "edlib-oracle"
MAX_SEQUENCE_LENGTH = 4096


def decode_cigar(cigar, format):
    """Decode positive, maximal runs in exactly the selected CIGAR alphabet."""
    assert isinstance(cigar, str)
    alphabet = "MID" if format == CigarFormat.STANDARD else "=XID"
    assert re.fullmatch(rf"(?:[1-9][0-9]*[{alphabet}])*", cigar) is not None, cigar
    runs = tuple((int(count), symbol) for count, symbol in re.findall(r"([0-9]+)(.)", cigar))
    assert all(a[1] != b[1] for a, b in zip(runs, runs[1:])), runs
    return runs


def assert_valid_cigar(query, segment, config, cigar, distance):
    """Recover operations and cost from CIGAR and input bytes, without a path."""
    query, segment = sequence_bytes(query), sequence_bytes(segment)
    pairs = {tuple(pair.to_bytes()) for pair in config.equalities}
    pairs |= {(b, a) for a, b in pairs}
    q = t = cost = 0
    operations = []
    for count, symbol in decode_cigar(cigar, config.cigar_format):
        if symbol == "I":
            assert q + count <= len(query), (q, t, cigar)
            q += count
            cost += count
            operations.extend([Operation.INSERT] * count)
        elif symbol == "D":
            assert t + count <= len(segment), (q, t, cigar)
            t += count
            cost += count
            operations.extend([Operation.DELETE] * count)
        else:
            assert q + count <= len(query) and t + count <= len(segment)
            for a, b in zip(query[q:q + count], segment[t:t + count]):
                matches = a == b or (a, b) in pairs
                if symbol == "=":
                    assert matches, (q, t, a, b, cigar)
                elif symbol == "X":
                    assert not matches, (q, t, a, b, cigar)
                operations.append(Operation.MATCH if matches else Operation.MISMATCH)
                cost += not matches
            q += count
            t += count
        assert q <= len(query) and t <= len(segment), (q, t, cigar)
    assert (q, t, cost) == (len(query), len(segment), distance)
    return tuple(operations)


def assert_valid_path(query, target, config, result):
    """Check semantics independently of the chosen optimal-path tie policy."""
    query, target = sequence_bytes(query), sequence_bytes(target)
    if result.alignment is None:
        assert config.task != Task.PATH or result.edit_distance < 0 or not query or not target
        assert result.cigar is None
        return
    assert result.start_locations is not None
    assert len(result.start_locations) == len(result.end_locations) > 0
    start = result.start_locations[0].to_edlib()
    end = result.end_locations[0].to_edlib()
    assert 0 <= start <= end + 1 <= len(target)
    segment = target[start:end + 1]
    pairs = {tuple(pair.to_bytes()) for pair in config.equalities}
    pairs |= {(b, a) for a, b in pairs}
    q = t = cost = 0
    for operation in result.alignment:
        if operation in (Operation.MATCH, Operation.MISMATCH):
            assert q < len(query) and t < len(segment), (q, t, operation)
            matches = query[q] == segment[t] or (query[q], segment[t]) in pairs
            assert matches == (operation == Operation.MATCH), (q, t, operation)
            q += 1
            t += 1
        elif operation == Operation.INSERT:
            assert q < len(query), (q, t, operation)
            q += 1
        elif operation == Operation.DELETE:
            assert t < len(segment), (q, t, operation)
            t += 1
        else:
            raise AssertionError(f"Unknown operation: {operation!r}")
        cost += operation != Operation.MATCH
    assert (q, t, cost) == (len(query), len(segment), result.require_distance())
    assert assert_valid_cigar(query, segment, config, result.cigar,
                              result.require_distance()) == result.alignment


def execute(
    command: Sequence[str | Path], *, timeout: float = 10, check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run literal argv and retain both streams in actionable failure messages."""
    argv = [str(arg) for arg in command]
    try:
        result = subprocess.run(
            argv, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
            timeout=timeout, check=False, env=reproducible_env(),
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
    # --RTS preserves empty strings and sequences that look like runtime flags.
    return execute([
        binary, *runtime_prefix(threads=threads), query, target,
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
    worker = cached_worker([binary, *runtime_prefix(threads=threads), "--worker"], cwd=ROOT)
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
