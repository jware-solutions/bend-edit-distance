"""Ordered independent CPU jobs, work balancing and deterministic full results."""

from dataclasses import replace
import itertools
import json
import math
import random
import subprocess

import pytest
from hypothesis import given, settings, strategies as st

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Task
from tests.helpers import ROOT, assert_valid_path, bend_align, cpp_edlib_align
from transport import LENGTH, decode_response, encode_request


def invoke(binary, jobs, threads, mode="batch"):
    result = subprocess.run(
        [str(binary), "--threads", str(threads), "--", mode, str(len(jobs))],
        cwd=ROOT, input=b"".join(encode_request(*job) for job in jobs),
        capture_output=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    if mode == "plan":
        return json.loads(result.stdout)
    output = result.stdout
    results = []
    while output:
        assert len(output) >= LENGTH.size
        size = LENGTH.unpack_from(output)[0]
        assert len(output) >= size + LENGTH.size
        results.append(decode_response(output[4:4 + size]))
        output = output[4 + size:]
    assert len(results) == len(jobs)
    return results


def singles(jobs, binary, threads=1):
    return [bend_align(q, t, c, binary=binary, threads=threads) for q, t, c in jobs]


@pytest.mark.parametrize("count", [0, 1, 2, 3, 7, 16, 31, 64])
def test_batch_cardinality_and_order(batch_probe, bend_binary, count):
    jobs = [(bytes([i]) * (i % 9), b"Z" * (i % 13), AlignConfig()) for i in range(count)]
    expected = singles(jobs, bend_binary)
    for threads in (1, 2, 4):
        assert invoke(batch_probe, jobs, threads) == expected


def mixed_jobs():
    sequences = [
        (b"", b""), (b"AC", b""), (b"", b"AC"),
        (b"\0\x80\xffaN", b"T\xff\0\x80ACaN"),
        (b"A" * 31, b"T" + b"A" * 33),
        (b"AC" * 32 + b"N", b"AC" * 48 + b"T"),
        (b"ACGT" * 32 + b"A", b"TGCA" * 48 + b"C"),
        (b"A", b"A" * 257), (b"A" * 513, b"TAC"),
    ]
    jobs = []
    for i, (mode, task, format) in enumerate(itertools.product(Mode, Task, CigarFormat)):
        q, t = sequences[i % len(sequences)]
        config = AlignConfig(mode, task, equalities=(
            EqualityPair(0, 255), EqualityPair("a", "A"),
            EqualityPair("N", "A"), EqualityPair("N", "C")), cigar_format=format)
        jobs.append((q, t, config))
        jobs.append((t, q, replace(config, threshold=MaxDistance(i % 3))))
    # Include several large accepted Hirschberg paths and repeated optimal ends.
    jobs += [(sequences[6][0], sequences[6][1], AlignConfig(task=Task.PATH)),
             (b"AC", b"TACGAC" * 20, AlignConfig(Mode.HW, Task.PATH)),
             (bytes(range(256)), bytes(range(256)), AlignConfig(task=Task.PATH))]
    return jobs


def test_mixed_jobs_full_results_and_thread_determinism(batch_probe, bend_binary, cpp_binary):
    jobs = mixed_jobs()
    expected = singles(jobs, bend_binary)
    for job, result in zip(jobs, expected):
        q, t, config = job
        oracle = cpp_edlib_align(q, t, config, binary=cpp_binary)
        assert (result.status, result.distance, result.end_locations, result.start_locations) == (
            oracle.status, oracle.distance, oracle.end_locations, oracle.start_locations)
        assert_valid_path(q, t, config, result)
    for threads in (1, 2, 4):
        assert singles(jobs, bend_binary, threads) == expected
        for _ in range(2):
            assert invoke(batch_probe, jobs, threads) == expected
    # Reordering the same jobs must reorder results, including duplicate inputs.
    order = list(range(len(jobs))) + [3, 3, 0]
    random.Random(20261012).shuffle(order)
    for threads in (1, 2, 4):
        assert invoke(batch_probe, [jobs[i] for i in order], threads) == [expected[i] for i in order]


def leaves(plan):
    if plan is None:
        return []
    if isinstance(plan, dict):
        assert math.isfinite(plan["work"]) and plan["work"] > 0
        return [plan]
    assert isinstance(plan, list) and len(plan) == 2
    left, right = map(leaves, plan)
    assert left and right
    assert abs(len(left) - len(right)) <= 1
    return left + right


@pytest.mark.parametrize("count", [0, 1, 2, 3, 17, 65, 129])
def test_plans_are_bounded_and_keep_each_job(batch_probe, count):
    jobs = [(b"A" * (i % 65), b"A" * (i % 129), AlignConfig()) for i in range(count)]
    plan = invoke(batch_probe, jobs, 1, "plan")
    assert sorted(leaf["index"] for leaf in leaves(plan)) == list(range(count))
    for threads in (2, 4):
        assert invoke(batch_probe, jobs, threads, "plan") == plan


def test_work_grouping_separates_clustered_heavy_jobs(batch_probe):
    jobs = [(b"A" * n, b"C" * n, AlignConfig()) for n in [512] * 4 + [1] * 4]
    plan = invoke(batch_probe, jobs, 1, "plan")
    left, right = map(leaves, plan)
    assert sum(item["index"] < 4 for item in left) == 2
    assert sum(item["index"] < 4 for item in right) == 2
    assert sum(item["work"] for item in left) == sum(item["work"] for item in right)


@settings(max_examples=20, deadline=None, derandomize=True)
@given(st.lists(st.tuples(st.binary(max_size=80), st.binary(max_size=100),
                          st.sampled_from(list(Mode)), st.sampled_from(list(Task)),
                          st.one_of(st.none(), st.integers(0, 80))), max_size=12))
def test_generated_batches_match_each_single_pair(batch_probe, bend_binary, values):
    jobs = []
    for q, t, mode, task, maximum in values:
        config = AlignConfig(mode, task)
        if maximum is not None:
            config = replace(config, threshold=MaxDistance(maximum))
        jobs.append((q, t, config))
    expected = singles(jobs, bend_binary)
    for threads in (1, 2, 4):
        assert invoke(batch_probe, jobs, threads) == expected
