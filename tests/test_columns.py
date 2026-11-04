"""Every packed block and carry against the original guarded column pass."""

import random
import subprocess

import pytest

from alignment import AlignConfig, EqualityPair, MaxDistance, Mode
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from transport import encode_request


@pytest.fixture(scope="module")
def column_probe(bend_tool):
    binary = ROOT / "build" / "column-probe"
    execute([bend_tool, ROOT / "tests/column_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("alphabet", [b"A", b"ACN\0\xff", bytes(range(256))])
def test_owned_column_equivalence(column_probe, threads, alphabet):
    rng = random.Random(210)
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    for length in [0, 1, 31, 32, 33, 257, 993, *range(1024, 1056), 4097, 8193]:
        query = (alphabet * (length // len(alphabet) + 1))[:length]
        target = bytes(range(256)) + bytes(rng.choices(alphabet, k=64))
        count = (length + 31) // 32
        for mode, first in [(Mode.NW, 0), (Mode.SHW, 1), (Mode.HW, max(0, count - 16)),
                            (Mode.NW, count + 1)]:
            config = AlignConfig(mode=mode, threshold=MaxDistance(first), equalities=pairs)
            result = subprocess.run([column_probe, *runtime_prefix(threads=threads)],
                input=encode_request(query, target, config), capture_output=True, check=True, timeout=30)
            assert result.stderr == b""
            values = result.stdout.splitlines()
            assert len(values) == 2 and values[0] == values[1], (length, mode, first)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_narrow_selected_rows_match_guarded_columns(column_probe, threads):
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    for alphabet in (b"ACN\0\xff", bytes(range(256))):
        for length in (base + tail for base in (32, 64, 128, 256, 1024) for tail in range(32)):
            query = (alphabet * (length // len(alphabet) + 1))[:length]
            count = (length + 31) // 32
            for active in (value for value in (1, 2, 3, 4, 7, 8) if value <= count):
                config = AlignConfig(threshold=MaxDistance(count - active), equalities=pairs)
                result = subprocess.run([column_probe, *runtime_prefix(threads=threads)],
                    input=encode_request(query, bytes(range(256)) + query[:65], config),
                    capture_output=True, check=True, timeout=30)
                assert not result.stderr
                values = result.stdout.splitlines()
                assert len(values) == 2 and values[0] == values[1], (length, active, threads)
