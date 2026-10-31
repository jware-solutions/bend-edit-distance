"""Framed worker streams across buffering, fragmentation and failed requests."""

import struct
import subprocess
import sys
import time

import pytest

import transport
from alignment import AlignConfig, Task
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from transport import AlignmentWorker, LENGTH


FAKE_WORKER = r'''
import struct, sys, time
kind = sys.argv[1]
source, output = sys.stdin.buffer, sys.stdout.buffer
def frame(payload):
    return struct.pack('<I', len(payload)) + payload
def control(op, count, status=0, handle=17):
    return frame(struct.pack('<4sIIIII', b'BER2', op, status, handle, 4096 if op != 3 else 0, count))
def result(length, path=False):
    missing = 0xffffffff
    cigar = (str(length) + '=').encode() if path else b''
    header = struct.pack('<4sIiIIII', b'BER1', 0, 0 if path else length,
                         1, 1 if path else missing, length if path else missing,
                         len(cigar) if path else missing)
    body = struct.pack('<i', length - 1)
    if path:
        body += struct.pack('<i', 0) + bytes(length) + cigar
    return frame(header + body)
def send(data):
    if kind.endswith('fragment'):
        sizes = (1, 3, 2, 31, 4095, 65537)
        offset = index = 0
        while offset < len(data):
            size = sizes[index % len(sizes)]
            output.write(data[offset:offset + size]); output.flush()
            offset += size; index += 1
    else:
        output.write(data); output.flush()
while True:
    prefix = source.read(4)
    if not prefix:
        break
    size, = struct.unpack('<I', prefix)
    payload = source.read(size)
    assert len(payload) == size
    version, mode, task, fmt, operation, maximum, query, target, pairs = struct.unpack_from('<4sBBBBiIII', payload)
    if kind.startswith('owned_'):
        print('request', operation, file=sys.stderr, flush=True)
    if version == b'BED1':
        send(result(target, task == 2))
    elif operation == 1:
        send(control(1, 1))
    elif operation == 2:
        if kind == 'owned_deadline':
            time.sleep(0.05)
        send(result(target))
    elif operation in (6, 7):
        if kind == 'owned_deadline':
            time.sleep(0.05)
        if kind == 'owned_bad_count':
            send(control(operation, 1, 1, 0))
        elif kind == 'owned_bad_status':
            send(control(operation, 0, 2, 0))
        elif kind == 'owned_bad_operation':
            send(control(operation + 1, 0, 1, 0))
        elif kind == 'owned_bad_magic':
            bad = bytearray(control(operation, 0, 1, 0)); bad[4:8] = b'FAIL'
            send(bad)
        elif kind == 'owned_bad_handle':
            send(control(operation, 0, 1, 42))
        elif kind == 'owned_wrong_success_handle':
            send(control(operation, 0, 0, 42))
        elif kind == 'owned_rejected' and operation == 7:
            send(control(operation, 0, 1, 17))
        else:
            send(control(operation, 0, 1, 0))
    elif operation == 3:
        send(control(3, 0))
    elif operation == 5:
        values, offset = [], 24
        for _ in range(target):
            length, = struct.unpack_from('<I', payload, offset)
            offset += 4 + length
            values.append(result(length))
        assert offset == len(payload)
        header = control(5, target)
        body = b''.join(values)
        if kind == 'count':
            send(control(5, target + 1) + body)
        elif kind == 'length':
            send(header + frame(b'x') + body)
        elif kind == 'magic':
            bad = bytearray(body); bad[4:8] = b'FAIL'
            send(header + bad)
        elif kind == 'control':
            send(control(5, target, 2) + body)
        elif kind == 'prefix_eof':
            send(header + body[:2]); break
        elif kind == 'payload_eof':
            send(header + body[:13]); break
        elif kind == 'control_eof':
            send(header[:9]); break
        elif kind == 'timeout':
            send(header + values[0] + body[:2]); time.sleep(10); break
        else:
            send(header + body)
    else:
        raise AssertionError(operation)
'''


@pytest.fixture
def stream_worker(tmp_path):
    script = tmp_path / "worker.py"
    script.write_text(FAKE_WORKER)
    return lambda kind: AlignmentWorker([sys.executable, "-u", script, kind])


@pytest.mark.parametrize("kind", ["whole", "fragment"])
def test_coalesced_and_fragmented_batches_and_consecutive_requests(stream_worker, kind):
    targets = [bytes(i % 97) for i in range(4097)]
    with stream_worker(kind) as worker, worker.prepare(b"") as prepared:
        for values in (targets, [], targets[:1], targets[::-1]):
            results = prepared.align_batch(values)
            assert [result.require_distance() for result in results] == list(map(len, values))
            assert prepared.align(b"next").require_distance() == 4
            assert worker.align(b"", b"ordinary").require_distance() == 8
        sequence = b"A" * 131073
        result = worker.align(sequence, sequence, AlignConfig(task=Task.PATH))
        assert result.require_distance() == 0
        assert len(result.alignment) == len(sequence)
        assert result.cigar == "131073="
        assert prepared.align(b"after large response").require_distance() == 20


@pytest.mark.parametrize("kind,message", [("count", "Incorrect batch response count"),
    ("length", "Invalid response frame length"), ("magic", "BER1"),
    ("control", "Invalid control response"), ("prefix_eof", "closed stdout"),
    ("payload_eof", "closed stdout"), ("control_eof", "closed stdout"),
    ("timeout", "timed out")])
def test_buffered_protocol_failures_invalidate_handles(stream_worker, kind, message):
    with stream_worker(kind) as worker:
        prepared = worker.prepare(b"")
        error = ValueError if kind in {"count", "length", "magic", "control"} else RuntimeError
        with pytest.raises(error, match=message):
            prepared.align_batch([b"first", b"second"], timeout=0.15)
        assert worker.closed and prepared.released
        assert worker.retained_entries == worker.retained_bytes == 0
        with pytest.raises(RuntimeError, match="closed"):
            prepared.align(b"never retried")


def test_deadline_covers_already_buffered_frames(stream_worker, monkeypatch):
    original = transport.decode_response

    def slow_decode(frame):
        value = original(frame)
        time.sleep(0.08)
        return value

    with stream_worker("whole") as worker:
        prepared = worker.prepare(b"")
        monkeypatch.setattr(transport, "decode_response", slow_decode)
        with pytest.raises(RuntimeError, match="timed out"):
            prepared.align_batch([b"first", b"second"], timeout=0.04)
        assert worker.closed and prepared.released


@pytest.mark.parametrize("kind", ["owned_legacy", "owned_fragment"])
def test_optional_buffer_operations_negotiate_legacy_once(stream_worker, kind):
    with stream_worker(kind) as worker, worker.prepare(b"A") as prepared:
        for _ in range(3):
            assert prepared.align(b"next").edit_distance == 4
            assert [r.edit_distance for r in prepared.align_batch([b"", b"A", b"longer"])] == [0, 1, 6]
        assert worker._owned_supported == {6: False, 7: False}
        assert prepared.align_batch([]) == []
    lines = worker._diagnostics.splitlines()
    assert lines.count("request 6") == lines.count("request 7") == 1


@pytest.mark.parametrize("kind", ["owned_bad_count", "owned_bad_status", "owned_bad_operation", "owned_bad_magic",
                                  "owned_bad_handle", "owned_wrong_success_handle"])
@pytest.mark.parametrize("batch", [False, True])
def test_malformed_optional_rejections_close_without_legacy_resend(stream_worker, kind, batch):
    with stream_worker(kind) as worker:
        prepared = worker.prepare(b"A")
        with pytest.raises(ValueError):
            prepared.align_batch([b"A"]) if batch else prepared.align(b"A")
        assert worker.closed and prepared.released
    lines = worker._diagnostics.splitlines()
    assert "request 2" not in lines and "request 5" not in lines


def test_recognized_owned_batch_rejection_preserves_connection_without_resend(stream_worker):
    with stream_worker("owned_rejected") as worker, worker.prepare(b"A") as prepared:
        with pytest.raises(RuntimeError, match="Prepared batch request rejected"):
            prepared.align_batch([b"A"])
        assert not worker.closed and not prepared.released
        assert prepared.align(b"next").edit_distance == 4
    assert "request 5" not in worker._diagnostics.splitlines()


def test_optional_negotiation_keeps_original_deadline(stream_worker):
    with stream_worker("owned_deadline") as worker:
        prepared = worker.prepare(b"A")
        with pytest.raises(RuntimeError, match="timed out"):
            prepared.align(b"A", timeout=0.08)
        assert worker.closed and prepared.released


@pytest.fixture(scope="module")
def batch_output_probe(bend_tool):
    binary = ROOT / "build" / "batch-output-probe"
    execute([bend_tool, ROOT / "tests/batch_output.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_native_batch_flush_preserves_exact_frames(batch_output_probe, threads):
    done = subprocess.run([batch_output_probe, *runtime_prefix(threads=threads)],
        capture_output=True, check=True, timeout=30)
    assert done.stderr == b""
    frames, offset = [], 0
    while offset < len(done.stdout):
        size, = LENGTH.unpack_from(done.stdout, offset)
        offset += LENGTH.size
        frames.append(done.stdout[offset:offset + size])
        offset += size
    assert offset == len(done.stdout)
    assert len(frames) == 26
    assert frames[:8] == frames[9:17] == frames[18:]
    assert frames[8] == frames[17] == frames[0]
