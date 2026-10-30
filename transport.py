"""Persistent native alignment workers with a versioned byte protocol.

Use AlignmentWorker as a context manager to own a worker explicitly. The test
adapters use a session cache and close it at pytest teardown. Requests on one
worker are serialized; separate workers can run independently.
"""

from __future__ import annotations

import atexit
from dataclasses import dataclass
import os
from pathlib import Path
import selectors
import struct
import subprocess
import tempfile
import threading
import time

from alignment import AlignConfig, AlignResult, CigarFormat, Mode, Task

MAX_FRAME_LENGTH = 2**31 - 1
NULL_LENGTH = 2**32 - 1
REQUEST = struct.Struct("<4sBBBBiIII")
RESPONSE = struct.Struct("<4sIiIIII")
LENGTH = struct.Struct("<I")
CONTROL = struct.Struct("<4sIIIII")
MAX_PREPARED_ENTRIES = 32
MAX_RETAINED_BYTES = 64 * 1024 * 1024
MAX_BATCH_SIZE = 65536
READ_AHEAD_SIZE = 65536


def sequence_bytes(value: bytes | str) -> bytes:
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        try:
            return value.encode("ascii")
        except UnicodeEncodeError as error:
            raise ValueError("Text convenience inputs require ASCII; pass bytes for other values") from error
    raise TypeError("Sequences must be bytes or ASCII strings")


def encode_request(query: bytes | str, target: bytes | str, config: AlignConfig) -> bytes:
    if not isinstance(config, AlignConfig):
        raise TypeError("Expected AlignConfig")
    query, target = sequence_bytes(query), sequence_bytes(target)
    pairs = b"".join(p.to_bytes() for p in config.equalities)
    size = REQUEST.size + len(query) + len(target) + len(pairs)
    if size > MAX_FRAME_LENGTH:
        raise ValueError(f"Request exceeds maximum frame length of {MAX_FRAME_LENGTH} bytes")
    header = REQUEST.pack(
        b"BED1", list(Mode).index(config.mode), list(Task).index(config.task),
        list(CigarFormat).index(config.cigar_format), 0, config.threshold.to_edlib(),
        len(query), len(target), len(config.equalities),
    )
    return LENGTH.pack(size) + header + query + target + pairs


def decode_response(payload: bytes) -> AlignResult:
    """Decode and validate one complete response, including absent/empty fields."""
    if len(payload) < RESPONSE.size:
        raise ValueError("Expected complete binary alignment response header")
    magic, status, distance, ends, starts, ops, cigar = RESPONSE.unpack_from(payload)
    if magic != b"BER1":
        raise ValueError("Expected binary alignment response version BER1")
    counts = [0 if n == NULL_LENGTH else n for n in (starts, ops, cigar)]
    expected = RESPONSE.size + 4 * (ends + counts[0]) + counts[1] + counts[2]
    if ends == NULL_LENGTH or expected != len(payload):
        raise ValueError("Expected consistent binary alignment response lengths")
    offset = RESPONSE.size

    def coordinates(count):
        nonlocal offset
        if count == NULL_LENGTH:
            return None
        values = [p[0] for p in struct.iter_unpack("<i", payload[offset:offset + 4 * count])]
        offset += 4 * count
        return values

    end_values, start_values = coordinates(ends), coordinates(starts)
    operations = None if ops == NULL_LENGTH else list(payload[offset:offset + ops])
    offset += counts[1]
    try:
        cigar_text = None if cigar == NULL_LENGTH else payload[offset:].decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("Expected ASCII CIGAR in binary alignment response") from error
    return AlignResult.from_edlib({
        "status": status, "edit_distance": distance, "end_locations": end_values,
        "start_locations": start_values, "alignment": operations, "cigar": cigar_text,
    })


def encode_control(operation, *, handle=0, count=0, body=b"", config=AlignConfig(), pairs=0):
    if len(body) + REQUEST.size > MAX_FRAME_LENGTH:
        raise ValueError("Request exceeds maximum frame length")
    first = count if operation == 4 else handle
    target = count if operation == 5 else len(body) if operation == 2 else 0
    payload = REQUEST.pack(b"BED2", list(Mode).index(config.mode), list(Task).index(config.task),
        list(CigarFormat).index(config.cigar_format), operation, config.threshold.to_edlib(), first, target, pairs)
    return LENGTH.pack(len(payload) + len(body)) + payload + body


@dataclass(eq=False)
class PreparedQuery:
    """A worker-local handle, invalidated on release or worker close."""
    _worker: AlignmentWorker
    handle: int
    query_length: int
    equalities: tuple
    _released: bool = False

    @property
    def released(self):
        return self._released or self._worker.closed

    def align(self, target, config=AlignConfig(), *, timeout=10):
        return self._worker.align_prepared(self, target, config, timeout=timeout)

    def align_batch(self, targets, config=AlignConfig(), *, timeout=10):
        return self._worker.align_prepared_batch(self, targets, config, timeout=timeout)

    def release(self):
        return self._worker.release_prepared(self)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.release()


class AlignmentWorker:
    """One executable, many byte requests. Failures close it; calls never retry."""

    def __init__(self, command, *, cwd: Path | None = None):
        if os.name == "nt":
            raise RuntimeError("Native alignment workers must run in WSL")
        self.command = [str(arg) for arg in command]
        self._lock = threading.RLock()
        self._closed = False
        self._prepared = {}
        self._retained_bytes = 0
        self._read_buffer = b""
        self._read_offset = 0
        self._stderr = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                self.command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self._stderr, bufsize=0,
            )
        except OSError as error:
            self._stderr.close()
            raise RuntimeError(f"Could not run {self.command!r}: {error}") from error
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)

    @property
    def pid(self) -> int:
        return self.process.pid

    @property
    def closed(self) -> bool:
        return self._closed

    def _ready(self, pipe, event, deadline):
        with selectors.DefaultSelector() as selector:
            selector.register(pipe, event)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise TimeoutError("alignment request timed out")

    def _write(self, data: bytes, deadline):
        view = memoryview(data)
        while view:
            self._ready(self.process.stdin, selectors.EVENT_WRITE, deadline)
            try:
                count = os.write(self.process.stdin.fileno(), view)
            except BlockingIOError:
                continue
            view = view[count:]

    def _read(self, size: int, deadline) -> bytes:
        if time.monotonic() >= deadline:
            raise TimeoutError("alignment request timed out")
        available = len(self._read_buffer) - self._read_offset
        if size <= available:
            end = self._read_offset + size
            result = self._read_buffer[self._read_offset:end]
            self._read_offset = end
            if end == len(self._read_buffer):
                self._read_buffer = b""
                self._read_offset = 0
            return result
        chunks = [self._read_buffer[self._read_offset:]] if available else []
        size -= available
        self._read_buffer = b""
        self._read_offset = 0
        while size:
            if time.monotonic() >= deadline:
                raise TimeoutError("alignment request timed out")
            try:
                chunk = os.read(self.process.stdout.fileno(), READ_AHEAD_SIZE)
            except BlockingIOError:
                self._ready(self.process.stdout, selectors.EVENT_READ, deadline)
                continue
            if not chunk:
                raise EOFError("worker closed stdout before a complete response")
            if len(chunk) > size:
                chunks.append(chunk[:size])
                self._read_buffer = chunk
                self._read_offset = size
                size = 0
            else:
                chunks.append(chunk)
                size -= len(chunk)
        return b"".join(chunks)

    def align(self, query: bytes | str, target: bytes | str,
              config: AlignConfig = AlignConfig(), *, timeout: float = 10) -> AlignResult:
        frame = encode_request(query, target, config)
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        with self._lock:
            if self.closed:
                raise RuntimeError("Alignment worker is closed")
            deadline = time.monotonic() + timeout
            try:
                self._write(frame, deadline)
                size = LENGTH.unpack(self._read(4, deadline))[0]
                if not RESPONSE.size <= size <= MAX_FRAME_LENGTH:
                    raise ValueError("Expected valid binary alignment response frame length")
                return decode_response(self._read(size, deadline))
            except (OSError, EOFError, TimeoutError, ValueError) as error:
                self.close()
                message = (f"{error}; worker {self.command!r} exited {self.process.returncode}\n"
                           f"stderr:\n{self._diagnostics}")
                if isinstance(error, ValueError):
                    raise ValueError(message) from error
                raise RuntimeError(message) from error

    def _frame(self, deadline, minimum=RESPONSE.size):
        size = LENGTH.unpack(self._read(4, deadline))[0]
        if not minimum <= size <= MAX_FRAME_LENGTH:
            raise ValueError("Invalid response frame length")
        return self._read(size, deadline)

    def _control(self, deadline, operation):
        frame = self._frame(deadline, CONTROL.size)
        if len(frame) != CONTROL.size:
            raise ValueError("Invalid control response length")
        magic, op, status, handle, retained, count = CONTROL.unpack(frame)
        if (magic != b"BER2" or op != operation or status not in (0, 1)
                or retained > MAX_RETAINED_BYTES or count > MAX_BATCH_SIZE):
            raise ValueError("Invalid control response")
        return status, handle, retained, count

    def _exchange(self, frame, read, timeout):
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        with self._lock:
            if self.closed:
                raise RuntimeError("Alignment worker is closed")
            deadline = time.monotonic() + timeout
            try:
                self._write(frame, deadline)
                return read(deadline)
            except (OSError, EOFError, TimeoutError, ValueError) as error:
                self.close()
                message = (f"{error}; worker {self.command!r} exited {self.process.returncode}\n"
                           f"stderr:\n{self._diagnostics}")
                if isinstance(error, ValueError):
                    raise ValueError(message) from error
                raise RuntimeError(message) from error

    @property
    def retained_bytes(self):
        """Conservative cache admission bytes, including a metadata allowance."""
        return self._retained_bytes

    @property
    def retained_entries(self):
        return len(self._prepared)

    def prepare(self, query, equalities=(), *, timeout=10):
        query = sequence_bytes(query)
        config = AlignConfig(equalities=tuple(equalities))
        pairs = b"".join(p.to_bytes() for p in config.equalities)
        if len(query) > 1048576 or len(config.equalities) > 65536:
            raise ValueError("Prepared query exceeds worker admission limits")
        payload = REQUEST.pack(b"BED2", 0, 0, 0, 1, 0, len(query), 0, len(config.equalities)) + query + pairs
        with self._lock:
            status, handle, retained, count = self._exchange(LENGTH.pack(len(payload)) + payload,
                lambda deadline: self._control(deadline, 1), timeout)
            self._retained_bytes = retained
            if status:
                raise RuntimeError("Prepared query cache limit exceeded")
            if not handle or handle in self._prepared or count != 1:
                self.close()
                raise ValueError("Invalid prepared handle response")
            prepared = PreparedQuery(self, handle, len(query), config.equalities)
            self._prepared[handle] = prepared
            return prepared

    def _prepared_options(self, prepared, config):
        if self.closed:
            raise RuntimeError("Alignment worker is closed")
        if (not isinstance(prepared, PreparedQuery) or prepared._worker is not self
                or prepared.released or self._prepared.get(prepared.handle) is not prepared):
            raise ValueError("Prepared query is released or belongs to another worker")
        if not isinstance(config, AlignConfig):
            raise TypeError("Expected AlignConfig")
        if config.equalities and config.equalities != prepared.equalities:
            raise ValueError("Prepared query equality definition is fixed")

    def align_prepared(self, prepared, target, config=AlignConfig(), *, timeout=10):
        target = sequence_bytes(target)
        with self._lock:
            self._prepared_options(prepared, config)
            frame = encode_control(2, handle=prepared.handle, body=target, config=config)
            return self._exchange(frame, lambda deadline: decode_response(self._frame(deadline)), timeout)

    def _batch_response(self, operation, count, deadline):
        control = self._control(deadline, operation)
        if control[0]:
            return control, []
        if control[3] != count:
            raise ValueError("Incorrect batch response count")
        return control, [decode_response(self._frame(deadline)) for _ in range(count)]

    def align_batch(self, jobs, *, timeout=10):
        jobs = list(jobs)
        if len(jobs) > MAX_BATCH_SIZE:
            raise ValueError("Batch exceeds worker limit")
        # Complete arguments precede the server's execution forks.
        frames = b"".join(encode_request(*job) for job in jobs)
        header = REQUEST.pack(b"BED2", 0, 0, 0, 4, 0, len(jobs), 0, 0)
        with self._lock:
            control, values = self._exchange(LENGTH.pack(len(header)) + header + frames,
                lambda deadline: self._batch_response(4, len(jobs), deadline), timeout)
            self._retained_bytes = control[2]
            if control[0]:
                raise RuntimeError("Batch request rejected")
            return values

    def align_prepared_batch(self, prepared, targets, config=AlignConfig(), *, timeout=10):
        targets = [sequence_bytes(t) for t in targets]
        if len(targets) > MAX_BATCH_SIZE:
            raise ValueError("Batch exceeds worker limit")
        body = b"".join(LENGTH.pack(len(t)) + t for t in targets)
        with self._lock:
            self._prepared_options(prepared, config)
            frame = encode_control(5, handle=prepared.handle, count=len(targets), body=body,
                pairs=len(body), config=config)
            control, values = self._exchange(frame,
                lambda deadline: self._batch_response(5, len(targets), deadline), timeout)
            self._retained_bytes = control[2]
            if control[0]:
                raise RuntimeError("Prepared batch request rejected")
            return values

    def release_prepared(self, prepared, *, timeout=10):
        with self._lock:
            if not isinstance(prepared, PreparedQuery) or prepared._worker is not self:
                raise ValueError("Prepared query belongs to another worker")
            if prepared.released:
                return False
            self._prepared_options(prepared, AlignConfig())
            # Control-only commands reserve all configuration bytes as zero.
            payload = REQUEST.pack(b"BED2", 0, 0, 0, 3, 0, prepared.handle, 0, 0)
            status, handle, retained, count = self._exchange(LENGTH.pack(len(payload)) + payload,
                lambda deadline: self._control(deadline, 3), timeout)
            if status or handle != prepared.handle or count:
                self.close()
                raise ValueError("Invalid prepared release response")
            self._retained_bytes = retained
            prepared._released = True
            del self._prepared[prepared.handle]
            return True

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
            for prepared in self._prepared.values():
                prepared._released = True
            self._prepared.clear()
            self._retained_bytes = 0
            self._read_buffer = b""
            self._read_offset = 0
            self.process.stdin.close()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
            self._stderr.seek(0)
            self._diagnostics = self._stderr.read(65536).decode("utf-8", errors="replace")
            self._stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


_workers: dict[tuple[str, ...], AlignmentWorker] = {}
_workers_lock = threading.Lock()


def cached_worker(command, *, cwd=None) -> AlignmentWorker:
    key = (str(cwd), *(str(arg) for arg in command))
    with _workers_lock:
        worker = _workers.get(key)
        if worker is None:
            worker = AlignmentWorker(command, cwd=cwd)
            _workers[key] = worker
        return worker


def close_workers():
    with _workers_lock:
        for worker in _workers.values():
            worker.close()
        _workers.clear()


atexit.register(close_workers)
