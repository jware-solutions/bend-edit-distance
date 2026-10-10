"""Reproducible three-way distance and persistent-worker timing comparison in WSL.

First build the binaries with python3 run_tests.py --alignment, then run
python3 -m tests.compare --repeats 5. Timings exclude warmed worker startup and
include byte transport, alignment and response decoding.
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import statistics
import sys
import time

from tests.helpers import (
    BEND_BINARY, CPP_BINARY, DP_BINARY, bend_distance, bend_dp_distance, cpp_edlib_distance,
)


def cases():
    rng = random.Random(20261008)
    yield "empty", "", ""
    yield "example", "kitten", "sitting"
    for length in (32, 128, 512):
        yield (
            f"dna-{length}",
            "".join(rng.choices("ACGT", k=length)),
            "".join(rng.choices("ACGT", k=length)),
        )
    alphabet = "".join(chr(code) for code in range(1, 128))
    yield "ascii-1024", "".join(rng.choices(alphabet, k=1024)), "".join(
        rng.choices(alphabet, k=1024)
    )
    yield "bytes-1024", rng.randbytes(1024), rng.randbytes(1024)
    yield "unequal", "ACG", "ACGT" * 1024
    yield "unequal-reversed", "ACGT" * 1024, "ACG"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--threads", type=int, default=1, help="CPU threads for both Bend binaries")
    args = parser.parse_args()
    if os.name == "nt":
        parser.error("Run in WSL: wsl --exec python3 -m tests.compare")
    if args.repeats < 1 or args.threads < 1:
        parser.error("--repeats and --threads must be positive")
    if not all(binary.is_file() for binary in (DP_BINARY, BEND_BINARY, CPP_BINARY)):
        parser.error("Build all three binaries first: python3 run_tests.py --alignment")

    algorithms = [
        ("dp", lambda q, t: bend_dp_distance(q, t, threads=args.threads)),
        ("myers", lambda q, t: bend_distance(q, t, threads=args.threads)),
        ("cpp_edlib", cpp_edlib_distance),
    ]
    print(
        f"Median persistent-worker request time in ms; excludes startup; "
        f"repeats={args.repeats}, Bend threads={args.threads}, seed=20261008.",
        file=sys.stderr,
    )
    writer = csv.writer(sys.stdout)
    writer.writerow(["case", "query_length", "target_length", "distance",
                     "dp_ms", "myers_ms", "cpp_edlib_ms"])
    for name, query, target in cases():
        # Validate the same ordered inputs and warm each persistent worker.
        distances = {algorithm: align(query, target) for algorithm, align in algorithms}
        if len(set(distances.values())) != 1:
            raise RuntimeError(f"Distance mismatch for {name}: {distances}")
        expected = distances["cpp_edlib"]
        samples: dict[str, list[float]] = {algorithm: [] for algorithm, _ in algorithms}
        for repetition in range(args.repeats):
            # Rotate invocation order to avoid always favoring the same binary.
            offset = repetition % len(algorithms)
            for algorithm, align in algorithms[offset:] + algorithms[:offset]:
                start = time.perf_counter()
                distance = align(query, target)
                samples[algorithm].append((time.perf_counter() - start) * 1000)
                if distance != expected:
                    raise RuntimeError(f"Distance mismatch for {name}, {algorithm}: {distance}")
        writer.writerow([
            name, len(query), len(target), expected,
            *(f"{statistics.median(samples[algorithm]):.3f}" for algorithm, _ in algorithms),
        ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
