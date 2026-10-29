"""Native framing is byte-for-byte equivalent to the pure BER1 encoder."""

import struct
from pathlib import Path

import pytest

from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from alignment import AlignConfig, Mode, Task
from transport import AlignmentWorker


@pytest.fixture(scope="module")
def response_fields_probe(bend_tool):
    binary = ROOT / "build" / "response-fields"
    execute([bend_tool, ROOT / "tests/response_fields.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_native_fields_match_pure_response(response_fields_probe, threads):
    import subprocess
    result = subprocess.run([response_fields_probe, *runtime_prefix(threads=threads)],
        capture_output=True, check=True, timeout=30)
    assert result.stderr == b""
    frames = []
    offset = 0
    while offset < len(result.stdout):
        size = struct.unpack_from("<I", result.stdout, offset)[0]
        offset += 4
        frames.append(result.stdout[offset:offset + size])
        offset += size
    assert offset == len(result.stdout)
    assert len(frames) == 16
    for index in range(0, len(frames), 2):
        assert frames[index] == frames[index + 1], index // 2


def test_repeated_native_responses_release_field_owners(bend_binary):
    config = AlignConfig(Mode.HW, Task.LOC)
    with AlignmentWorker([bend_binary, *runtime_prefix(threads=1), "--worker"]) as worker:
        status = Path(f"/proc/{worker.process.pid}/status")
        if not status.is_file():
            pytest.skip("Requires Linux process memory accounting")

        def rss():
            return next(int(line.split()[1]) for line in status.read_text().splitlines()
                        if line.startswith("VmRSS:"))

        for _ in range(8):
            worker.align(b"A", b"C" * 8193, config)
        baseline = rss()
        for _ in range(96):
            result = worker.align(b"A", b"C" * 8193, config)
            assert result.edit_distance == 1
            assert len(result.end_locations) == len(result.start_locations) == 8194
        # Losing either converted location owner retains over 12 MiB here.
        assert rss() - baseline < 8 * 1024
