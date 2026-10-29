"""Native prepared requests preserve validated byte lengths and payloads."""

import struct
import subprocess

import pytest

from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from transport import LENGTH, NULL_LENGTH, RESPONSE, encode_control


@pytest.fixture(scope="module")
def sized_target_probe(bend_tool):
    binary = ROOT / "build" / "sized-target-probe"
    execute([bend_tool, ROOT / "tests/sized_targets.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_native_target_lengths_and_contents(sized_target_probe, threads):
    targets = [b"", b"\0", b"\xc0\xaf\x80\xff", bytes(range(256)) * 33]
    targets += [bytes(range(256))[:length] for length in range(31, 98)]
    frames = [([target], encode_control(2, handle=17, body=target)) for target in targets]
    body = b"".join(LENGTH.pack(len(target)) + target for target in targets)
    frames += [(targets, encode_control(5, handle=17, count=len(targets), body=body, pairs=len(body)))]
    for expected, request in frames:
        done = subprocess.run([sized_target_probe, *runtime_prefix(threads=threads)],
            input=request, capture_output=True, check=True, timeout=30)
        assert done.stderr == b""
        offset = 0
        for target in expected:
            size, = LENGTH.unpack_from(done.stdout, offset)
            offset += LENGTH.size
            frame = done.stdout[offset:offset + size]
            offset += size
            assert RESPONSE.unpack_from(frame) == (
                b"BER1", 0, len(target), 1, NULL_LENGTH, NULL_LENGTH, len(target))
            assert struct.unpack_from("<i", frame, RESPONSE.size) == (len(target) - 1,)
            assert frame[RESPONSE.size + 4:] == target
        assert offset == len(done.stdout)
