"""Every exact bit-parallel prefix score against independent scalar DP."""

import random
import subprocess

import pytest

from alignment import AlignConfig, EqualityPair
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from transport import encode_request


@pytest.fixture(scope="module")
def frontier_probe(bend_tool):
    binary = ROOT / "build" / "frontier-probe"
    execute([bend_tool, ROOT / "tests" / "frontier_probe.bend", "-o", binary], timeout=180)
    return binary


def scalar(query, target, pairs):
    equal = {tuple(p.to_bytes()) for p in pairs}
    equal |= {(b, a) for a, b in equal}
    row = list(range(len(target) + 1))
    for i, q in enumerate(query, 1):
        next_row = [i]
        for j, t in enumerate(target, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1,
                row[j - 1] + (q != t and (q, t) not in equal)))
        row = next_row
    return row


def scores(binary, query, target, pairs=(), threads=1):
    result = subprocess.run([binary, *runtime_prefix(threads=threads)],
        input=encode_request(query, target, AlignConfig(equalities=pairs)), capture_output=True, check=True, timeout=30)
    assert result.stderr == b""
    return [int(x) for x in result.stdout.strip().split(b",")]


@pytest.mark.parametrize("length", [0, *range(1, 34), 63, 64, 65, 95, 96, 97, 127, 128, 129, 257])
def test_every_padding_and_word_boundary(frontier_probe, length):
    rng = random.Random(171 + length)
    query = bytes(rng.choices(range(256), k=length))
    target = query[3:] + b"\0\xffXYZ"
    pairs = (EqualityPair(0, 255), EqualityPair(255, 127), EqualityPair("A", "N"), EqualityPair("N", "C"))
    assert scores(frontier_probe, query, target, pairs) == scalar(query, target, pairs)
    assert scores(frontier_probe, query, b"", pairs) == [length]


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_arbitrary_bytes_and_empty_prefix(frontier_probe, threads):
    query = bytes(range(256))
    targets = [b"", query, query[::-1], b"A" * 65, b"\0" * 257]
    pairs = (EqualityPair(0, 255), EqualityPair(255, 127))
    for target in targets:
        actual = scores(frontier_probe, query, target, pairs, threads)
        assert actual[0] == len(query)
        assert actual == scalar(query, target, pairs)


def test_large_skew_and_nontransitive_equalities(frontier_probe):
    query = b"AN\0\xffC" * 821
    target = b"CA\xff\0N" * 7
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    assert scores(frontier_probe, query, target, pairs) == scalar(query, target, pairs)


@pytest.mark.parametrize('threads', [1, 2, 4])
def test_midpoints_scan_all_candidates_and_keep_first_minimum(frontier_probe, threads):
    rng = random.Random(9901)
    pairs = (EqualityPair('A', 'N'), EqualityPair('N', 'C'), EqualityPair('A', 'N'),
             EqualityPair('N', 'A'), EqualityPair('A', 'A'), EqualityPair(0, 255))
    cases = [(b'AA', b'AAA'), (b'AC' * 65, b'CA' * 65),
             (b'A' * 257, b'A' * 3), (b'ABC', b'Z' * 1025 + b'ABC'),
             (b'ABC', b'ABC' + b'Z' * 1025), (b'', b''), (b'ANC', b''),
             (bytes(range(256)), bytes(reversed(range(256))))]
    for qn, tn in ((31, 129), (33, 257), (65, 17), (97, 65), (129, 513)):
        cases.append((bytes(rng.choices(b'ACN\0\xff', k=qn)), bytes(rng.choices(b'ACN\0\xff', k=tn))))
    for query, target in cases:
        half = len(query) // 2
        forward = scalar(query[:half], target, pairs)
        reverse = scalar(query[half:][::-1], target[::-1], pairs)
        costs = [a + b for a, b in zip(forward, reversed(reverse))]
        result = subprocess.run([frontier_probe, *runtime_prefix(threads=threads), 'midpoint'],
            input=encode_request(query, target, AlignConfig(equalities=pairs)),
            capture_output=True, check=True, timeout=30)
        assert int(result.stdout) == costs.index(min(costs))
        assert scores(frontier_probe, query, target, pairs, threads) == scalar(query, target, pairs)
