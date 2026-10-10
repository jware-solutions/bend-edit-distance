"""Byte preservation, persistence, framing and worker lifecycle regressions."""

import itertools
from concurrent.futures import ThreadPoolExecutor
import struct
import subprocess
import sys

import pytest
from hypothesis import given, settings, strategies as st

from alignment import (
    AlignConfig, AlignResult, BeforeStart, CigarFormat, DistanceFound,
    DistanceNotFound, EqualityPair, MaxDistance, Mode, Operation, Position, Status, Task,
)
from transport import (
    AlignmentWorker, LENGTH, MAX_FRAME_LENGTH, NULL_LENGTH, REQUEST, RESPONSE,
    cached_worker, decode_response, encode_request,
)
from tests.helpers import ROOT, bend_align, bend_distance, bend_dp_distance, cpp_edlib_align


@pytest.fixture(params=["bend_binary", "cpp_binary"])
def command(request):
    binary = request.getfixturevalue(request.param)
    runtime = ["--threads", "1", "--"] if request.param == "bend_binary" else []
    return [binary, *runtime, "--worker"]


def frames(output):
    results = []
    while output:
        assert len(output) >= 4
        size = LENGTH.unpack_from(output)[0]
        assert len(output) >= size + 4
        results.append(decode_response(output[4:4 + size]))
        output = output[4 + size:]
    return results


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("format", list(CigarFormat))
def test_configured_raw_bytes(bend_binary, cpp_binary, mode, task, format):
    query, target = b"\0\x80\xffA", b"\xff\0\x80BA\0"
    config = AlignConfig(mode, task, equalities=(EqualityPair(255, b"\0"),
                                                EqualityPair("A", b"B")), cigar_format=format)
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_all_256_values(bend_binary, dp_binary, cpp_binary, threads):
    alphabet = bytes(range(256))
    # Every symbol is exercised as both query and target, without text decoding.
    assert bend_distance(alphabet, alphabet, binary=bend_binary, threads=threads) == 0
    target = alphabet[1:] + alphabet[:1]
    assert bend_dp_distance(alphabet, target, binary=dp_binary, threads=threads) == 2
    config = AlignConfig(task=Task.PATH)
    assert bend_align(alphabet, alphabet, config, binary=bend_binary, threads=threads) == cpp_edlib_align(
        alphabet, alphabet, config, binary=cpp_binary)
    assert bend_distance(alphabet, target, binary=bend_binary, threads=threads) == cpp_edlib_align(
        alphabet, target, binary=cpp_binary).require_distance() == 2


def test_reuses_adapter_process(bend_binary, cpp_binary):
    for binary, align, runtime in ((bend_binary, bend_align, ["--threads", "1", "--"]),
                                   (cpp_binary, cpp_edlib_align, [])):
        align(b"\0A", b"\0", binary=binary)
        worker = cached_worker([binary, *runtime, "--worker"], cwd=ROOT)
        pid = worker.pid
        for i in range(200):
            symbol = bytes([i])
            assert align(symbol, b"", binary=binary).require_distance() == 1
            assert cached_worker([binary, *runtime, "--worker"], cwd=ROOT) is worker
            assert worker.pid == pid and worker.process.poll() is None


def test_concurrent_clients_share_one_worker(command):
    with AlignmentWorker(command, cwd=ROOT) as worker, ThreadPoolExecutor(max_workers=4) as pool:
        pid = worker.pid
        def align(n):
            return worker.align(bytes([n]) * n, b"").require_distance()
        assert list(pool.map(align, range(1, 32))) == list(range(1, 32))
        assert worker.pid == pid and worker.process.poll() is None


def test_exceeds_argument_length_limit(command):
    # Linux has a per-argument limit near 128 KiB. This frame bypasses argv and
    # the old 4,096-character adapter cap. Keep alignment work linear here.
    sequence = bytes(range(256)) * 600
    with AlignmentWorker(command, cwd=ROOT) as worker:
        result = worker.align(sequence, b"")
        assert result == AlignResult(Status.OK, DistanceFound(len(sequence)),
                                     (BeforeStart(),), None, None, None)
        assert worker.align(b"A\0B", b"A\0B").require_distance() == 0
    assert worker.closed and worker.process.poll() == 0


def test_worker_bypasses_text_sequence_and_equality_caps(command):
    with AlignmentWorker(command, cwd=ROOT) as worker:
        query = b"\0\x80\xff" * 1400
        assert worker.align(query, b"\0").require_distance() == len(query) - 1
        config = AlignConfig(task=Task.PATH, threshold=MaxDistance(2**31 - 1),
                             equalities=(EqualityPair(0, 255),) * 2050)
        assert worker.align(b"\0", b"\xff", config) == AlignResult(
            Status.OK, DistanceFound(0), (Position(0),), (Position(0),),
            (Operation.MATCH,), "1=")


def test_multiple_frames_and_recoverable_configuration_error(command):
    valid = encode_request(b"\0\xff", b"\0", AlignConfig(task=Task.PATH))
    invalid = bytearray(valid)
    invalid[8] = 3  # Invalid mode, with complete valid framing.
    result = subprocess.run(command, input=valid + invalid + valid, capture_output=True, cwd=ROOT, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stderr == b""
    first, error, last = frames(result.stdout)
    assert first == last
    assert first.require_distance() == 1
    assert error == AlignResult(Status.ERROR, DistanceNotFound(), (), None, None, None)


def test_fragmented_request_and_immediate_flush(command):
    with AlignmentWorker(command, cwd=ROOT) as worker:
        frame = encode_request(b"\0\x80\xff", b"\x80\xff", AlignConfig())
        # Native stdin stays open while the response is read. Byte-by-byte
        # writes exercise exact reads and do not require EOF to flush output.
        import time
        deadline = time.monotonic() + 10
        for byte in frame:
            worker._write(bytes([byte]), deadline)
        size = LENGTH.unpack(worker._read(4, deadline))[0]
        assert decode_response(worker._read(size, deadline)).require_distance() == 1
        assert worker.align(b"", b"\0").require_distance() == 1


@pytest.mark.parametrize("bad", [
    b"\x18", LENGTH.pack(23), LENGTH.pack(MAX_FRAME_LENGTH + 1),
    LENGTH.pack(24) + b"BAD1" + bytes(20),
    LENGTH.pack(24) + REQUEST.pack(b"BED1", 0, 0, 1, 0, -1, 1, 0, 0),
    encode_request(b"\0", b"A", AlignConfig())[:-1],
])
def test_bad_frames_fail_without_partial_response(command, bad):
    result = subprocess.run(command, input=bad, capture_output=True, cwd=ROOT, timeout=10)
    assert result.returncode == 2
    assert result.stdout == b""
    assert b"Byte transport:" in result.stderr


@pytest.mark.parametrize("offset,patch", [
    (8, b"\xff"), (9, b"\xff"), (10, b"\xff"), (11, b"\x01"),
    (12, struct.pack("<i", -2)),
])
def test_bad_configuration_fields_recover(command, offset, patch):
    valid = encode_request(b"\0", b"\xff", AlignConfig())
    bad = valid[:offset] + patch + valid[offset + len(patch):]
    result = subprocess.run(command, input=bad + valid, capture_output=True, cwd=ROOT, timeout=10)
    assert result.returncode == 0, result.stderr
    error, valid_result = frames(result.stdout)
    assert error.status == Status.ERROR
    assert valid_result.require_distance() == 1


@settings(max_examples=100, deadline=None, derandomize=True)
@given(query=st.binary(max_size=40), target=st.binary(max_size=40),
       mode=st.sampled_from(list(Mode)), task=st.sampled_from(list(Task)),
       maximum=st.integers(min_value=0, max_value=40),
       pairs=st.lists(st.tuples(st.integers(0, 255), st.integers(0, 255)), max_size=4))
def test_byte_differential(bend_binary, cpp_binary, query, target, mode, task, maximum, pairs):
    config = AlignConfig(mode, task, MaxDistance(maximum), tuple(EqualityPair(*p) for p in pairs))
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


@pytest.mark.alignment
def test_exhaustive_byte_domain(bend_binary, cpp_binary):
    sequences = [bytes(s) for n in range(3) for s in itertools.product((0, 128, 255), repeat=n)]
    for query, target, mode, task in itertools.product(sequences, sequences, Mode, Task):
        config = AlignConfig(mode, task)
        assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
            query, target, config, binary=cpp_binary), (query, target, config)


def test_binary_codec_preserves_present_empty_fields():
    response = RESPONSE.pack(b"BER1", 0, 0, 1, 1, 0, 0) + struct.pack("<ii", -1, 0)
    assert decode_response(response) == AlignResult(
        Status.OK, DistanceFound(0), (BeforeStart(),), (Position(0),), (), "")
    assert encode_request(b"\0\x80\xff", b"", AlignConfig(
        equalities=(EqualityPair(0, 255),)))[4 + REQUEST.size:] == b"\0\x80\xff\0\xff"


@pytest.mark.parametrize("payload", [
    b"", RESPONSE.pack(b"BAD1", 0, -1, 0, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH),
    RESPONSE.pack(b"BER1", 0, 0, 1, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH),
    RESPONSE.pack(b"BER1", 0, -2, 0, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH),
    RESPONSE.pack(b"BER1", 0, 0, 1, 1, 1, 2) + struct.pack("<ii", 0, 0) + b"\x041M",
])
def test_bad_response_is_rejected(payload):
    with pytest.raises(ValueError, match="Expected"):
        decode_response(payload)


@pytest.mark.parametrize("code,match,error_type", [
    ("import time; time.sleep(5)", "timed out", RuntimeError),
    ("import sys; print('diagnostic', file=sys.stderr); sys.exit(7)", "diagnostic", RuntimeError),
    ("import sys; sys.stdout.buffer.write(bytes(4)); sys.stdout.flush()", "Expected", ValueError),
])
def test_worker_failure_closes_process(code, match, error_type):
    with AlignmentWorker([sys.executable, "-c", code]) as worker:
        with pytest.raises(error_type, match=match):
            worker.align(b"A", b"A", timeout=0.1 if "sleep" in code else 10)
        assert worker.closed and worker.process.poll() is not None
        with pytest.raises(RuntimeError, match="closed"):
            worker.align(b"A", b"A")
