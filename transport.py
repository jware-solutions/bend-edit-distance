"""Persistent native alignment workers with a versioned byte protocol.

Use AlignmentWorker as a context manager to own a worker explicitly. The test
adapters use a session cache and close it at pytest teardown. Requests on one
worker are serialized; separate workers can run independently.
"""

from __future__ import annotations

import atexit
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


class AlignmentWorker:
    """One executable, many byte requests. Failures close it; calls never retry."""

    def __init__(self, command, *, cwd: Path | None = None):
        if os.name == "nt":
            raise RuntimeError("Native alignment workers must run in WSL")
        self.command = [str(arg) for arg in command]
        self._lock = threading.RLock()
        self._closed = False
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
        chunks = bytearray()
        while len(chunks) < size:
            self._ready(self.process.stdout, selectors.EVENT_READ, deadline)
            try:
                chunk = os.read(self.process.stdout.fileno(), min(size - len(chunks), 65536))
            except BlockingIOError:
                continue
            if not chunk:
                raise EOFError("worker closed stdout before a complete response")
            chunks.extend(chunk)
        return bytes(chunks)

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

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
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
