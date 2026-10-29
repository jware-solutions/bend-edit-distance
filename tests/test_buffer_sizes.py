"""Retained payload estimates against the pinned native allocator's classes."""

import subprocess

import pytest

from alignment import AlignConfig, EqualityPair
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from transport import AlignmentWorker, encode_request


@pytest.fixture(scope="module")
def payload_probe(bend_tool):
    binary = ROOT / "build" / "buffer-sizes"
    execute([bend_tool, ROOT / "tests" / "buffer_sizes.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("length", [0, 1, 31, 32, 33, 63, 64, 65, 97, 512, 4096, 8193])
@pytest.mark.parametrize("alphabet,pairs", [(b"A", ()),
    (bytes(range(256)), (EqualityPair(0, 255), EqualityPair(128, 127)))])
def test_payload_sizes_match_allocations(payload_probe, bend_binary, length, alphabet, pairs):
    query = (alphabet * (length // len(alphabet) + 1))[:length]
    result = subprocess.run([payload_probe, *runtime_prefix(threads=1, gpu="off")],
        input=encode_request(query, b"", AlignConfig(equalities=pairs)),
        capture_output=True, check=True, timeout=30)
    assert result.stderr == b""
    values = {parts[0]: [int(v) for v in parts[1:]]
              for line in result.stdout.decode().splitlines() if (parts := line.split(","))}
    assert values["workspace"][0] == values["workspace"][1]
    assert values["workspace"][2] == 0xffffffff  # Returned owner remains readable.
    assert values["profile"][0] == values["profile"][1]
    payload = 16 * length + 32 * len(pairs) + values["workspace"][0]
    if query:
        payload += values["profile"][0]
    with AlignmentWorker([bend_binary, *runtime_prefix(threads=1), "--worker"]) as worker:
        with worker.prepare(query, pairs):
            assert worker.retained_bytes == 4096 + 2 * payload
