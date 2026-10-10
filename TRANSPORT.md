# Persistent byte transport (version 1)

Compile `worker.bend` (`bend worker.bend -o build/bend-edit-distance`), then run
`build/bend-edit-distance --threads 1 -- --worker`.
The C++ oracle accepts `build/edlib-oracle --worker`. Both read binary requests
from stdin and flush one binary response to stdout per request, in order, until
EOF. Stderr contains diagnostics only. The independent DP test executable
supports the same transport for NW DISTANCE with ordinary equality.

All integers use little endian encoding. Each frame starts with a `u32` payload
length, excluding that four-byte prefix. Frame lengths must be between the
relevant header size and `2^31 - 1`, consistent with Edlib's signed length range.
No text encoding or terminator is applied to sequences or equality pairs.
There is no 4,096-byte sequence limit on workers; available memory and alignment
cost still bound practical input sizes. A worker processes requests sequentially;
use separate workers for concurrent requests. Bend still uses its configured
CPU threads for independent work within an alignment.

## Request

The fixed payload header is 24 bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | 4 bytes | Magic/version `BED1` |
| 4 | u8 | Mode: NW=0, SHW=1, HW=2 |
| 5 | u8 | Task: DISTANCE=0, LOC=1, PATH=2 |
| 6 | u8 | CIGAR format: STANDARD=0, EXTENDED=1 |
| 7 | u8 | Reserved; must be zero |
| 8 | i32 | Threshold: -1 for unlimited, otherwise nonnegative |
| 12 | u32 | Query length in bytes |
| 16 | u32 | Target length in bytes |
| 20 | u32 | Equality pair count |

The header is followed by the query bytes, target bytes, then two bytes for each
equality pair. These declared sizes must exactly account for the frame length.
All 256 byte values, including zero, are allowed everywhere in these arrays.
Pairs are symmetric and do not imply transitive equality.

## Response

The fixed payload header is 28 bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | 4 bytes | Magic/version `BER1` |
| 4 | u32 | Status: OK=0, ERROR=1 |
| 8 | i32 | Edit distance, or -1 when absent |
| 12 | u32 | End location count |
| 16 | u32 | Start location count, or `0xffffffff` when absent |
| 20 | u32 | Operation count, or `0xffffffff` when absent |
| 24 | u32 | CIGAR byte length, or `0xffffffff` when absent |

After the header come end coordinates (`i32` each), optional start coordinates
(`i32` each), optional operation bytes, and optional ASCII CIGAR bytes, in that
order. Coordinate -1 means before position zero. Operation bytes are match=0,
insertion=1, deletion=2, mismatch=3. CIGAR has no terminator. Present empty
arrays/strings use length zero and remain distinct from absent fields.

Invalid mode/task/format/reserved/threshold fields produce a normalized ERROR
response: distance -1, zero ends, and absent starts/operations/CIGAR. The worker
continues at the next frame. Missing distance due to a threshold uses the same
absent result fields with OK status. Edlib's empty-input behavior is preserved.

EOF between frames exits successfully. A partial frame, inconsistent lengths,
unsupported magic/version, invalid frame size, or IO failure exits with status
2 and a diagnostic. No partial response is emitted for a malformed request.
Clients must discard the worker after a timeout or incomplete/malformed response;
requests are never retried automatically. The termination-checked Bend loop has
fuel for `2^32 - 1` requests in one process.

## Python

`transport.AlignmentWorker` owns a process and provides synchronous typed
requests. Close it with a context manager:

```python
from alignment import AlignConfig, EqualityPair, Task
from transport import AlignmentWorker

config = AlignConfig(task=Task.PATH, equalities=(EqualityPair(0, 255),))
with AlignmentWorker(["build/bend-edit-distance", "--threads", "1", "--", "--worker"]) as worker:
    for query in (b"A\0C", bytes(range(256))):
        result = worker.align(query, query, config)
        assert result.require_distance() == 0
```

Sequences are `bytes`; ASCII `str` inputs are a convenience conversion. Encode
other text explicitly before calling so that distance counts bytes. Equality
pair components accept integers 0..255, single-byte `bytes`, or single-character
strings with code points 0..255 (mapped directly to that byte, without UTF-8).
`tests.helpers` caches one worker per executable/CPU-thread configuration and
closes all workers at pytest session teardown. `close_workers()` also provides
explicit teardown outside pytest. Calls sharing one worker use a lock; workers
with different commands operate independently.

`encode_request` and `decode_response` implement the wire codec separately from
process ownership. `AlignResult.to_edlib()` / `from_json()` can support an outer
JSON Lines convenience layer; JSON is not used inside the alignment transport.
The legacy text CLIs retain their non-NUL ASCII/4,096-character restrictions.
