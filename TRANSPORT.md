# Persistent byte transport

`lib.capabilities()` reports the current 32-bit kernel and unavailable U64/native
library capabilities. Word-dependent operations are isolated in `src/Word.bend`;
the pinned compiler currently supplies U32 and executable/C emission.

The future native ABI must use versioned runtime, prepared-query and result
handles. Initialization owns one runtime configuration; incompatible subsequent
initialization fails. Shutdown waits for callers and requires all handles to be
disposed. Input byte spans are borrowed only for the call; preparation copies
its query. Results own library-allocated memory and require exactly one library
dispose call. Prepared handles have one caller at a time; concurrent callers
clone them into independent workspaces. Runtime entry/disposal must be thread
safe, with no callbacks into a caller while holding an internal lock. Errors
use explicit status codes and caller-owned diagnostic buffers; threshold
rejection remains a successful result. Failed calls publish no partial handles.
Bindings and direct-call benchmarks require a supported compiler library target.

Compile `worker.bend` (`bend worker.bend -o build/bend-edit-distance`), then run
`build/bend-edit-distance +RTS --threads 1 -RTS --RTS --worker`.
The C++ oracle accepts `build/edlib-oracle --worker`. Both read binary requests
from stdin and flush one binary response to stdout per request, in order, until
EOF. Stderr contains diagnostics only. The independent DP test executable
supports the same transport for NW DISTANCE with ordinary equality.

`src/Transport.bend` owns both persistent worker IO (`read_request`, `serve`)
and counted batch IO (`read_batch`, `write_batch`). `src/ByteProtocol.bend`
contains the pure byte/configuration/result conversions. The native bridge in
`src/transport.c` is shared with `tests/edlib_oracle.cpp`; foreign effects stay
outside the laws' import graph. Batch probes use this production adapter.

All integers use little endian encoding. Each frame starts with a `u32` payload
length, excluding that four-byte prefix. Frame lengths must be between the
relevant header size and `2^31 - 1`, consistent with Edlib's signed length range.
No text encoding or terminator is applied to sequences or equality pairs.
There is no 4,096-byte sequence limit on workers; available memory and alignment
cost still bound practical input sizes. A worker processes requests sequentially;
use separate workers for concurrent requests. Bend still uses its configured
CPU threads for independent work within an alignment.

Use `--worker --shards 1`, `--worker --shards 2` or `--worker --shards 4` to
retain independent prepared profiles/workspaces for parallel CPU batches.
For example, use `+RTS --threads 4 -RTS --RTS --worker --shards 4`.
BED1/BED2 framing and worker-local handles are unchanged. Pool cloning targets
32 MiB, with at least one owner, within the existing 64 MiB/32-entry cache limit.
The pure CPU APIs are `lib.prepare_pool`, `align_prepared_pool` and
`align_prepared_pool_batch`; the requested maximum rounds down to a power of two
subject to the memory target, with a minimum of one owner.

## GPU batch entry point

Compile `gpu_batch.bend` to `build/gpu-batch`, then invoke
`build/gpu-batch +RTS --threads 4 --gpu on -RTS --RTS COUNT`. Send exactly COUNT ordinary BED1 request
frames on stdin. The program collects the jobs, prepares a balanced plan on
CPU, executes the independent alignment tree in one GPU `!` call, and writes
COUNT BER1 responses in input order. COUNT zero is valid. Missing/truncated
requests fail before batch evaluation. Additional input after COUNT frames is
outside this invocation's batch and is not consumed.

Pass `--worker` in place of COUNT for a persistent BED1/BED2 session, using the
same Python `AlignmentWorker` API as the CPU worker. Preparation clones a bounded
pool of independently owned masks/workspaces once. Successive prepared batches
reuse those owners, balance targets before the bang, and restore input order
after it. Waves contain at most 1,024 targets and one target per owner, avoiding
a pinned-runtime completion failure with serial reuse inside device leaves.
Cloning targets a 32 MiB pool budget, with at least one owner; the shared
64 MiB/32-entry cache limit still applies. GPU selection remains explicit.
Demand migration is the default.

Keep the compiled `.gpu` program beside the binary. `+RTS --gpu off -RTS` explicitly runs
the same entry point on CPU. Default GPU selection permits fallback; successful
responses alone do not demonstrate device execution. Use
`python run_gpu_benchmarks.py --check-build` for forced-device validation with
completed-dispatch evidence. The pure Bend APIs include `GpuBatch.align_batch`,
`prepare_query`, and `align_prepared_batch(pool, targets, options) -> (pool, results)`.

## Request

The fixed payload header is 24 bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | 4 bytes | Magic/version `BED1` |
| 4 | u8 | Mode: NW=0, SHW=1, HW=2 |
| 5 | u8 | Task: DISTANCE=0, LOC=1, PATH=2 |
| 6 | u8 | CIGAR format: STANDARD=0, EXTENDED=1 |
| 7 | u8 | Reserved; must be zero |
| 8 | i32 | Threshold: any negative value for unlimited, otherwise an inclusive maximum |
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

Invalid mode/task/format/reserved fields produce a normalized ERROR
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
from bend_runtime import runtime_prefix
from transport import AlignmentWorker

config = AlignConfig(task=Task.PATH, equalities=(EqualityPair(0, 255),))
with AlignmentWorker(["build/bend-edit-distance", *runtime_prefix(threads=1), "--worker"]) as worker:
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


## Prepared queries and batches (BED2)

The Bend CPU and persistent GPU workers accept `BED2`; BED1/BER1 remain compatible.
BED2 uses the same 24-byte request header, with byte 7 holding an operation.
Mode/task/format/threshold apply to operations 2 and 5, with the restricted
configuration below for optional operations 6/7. All four fields must be zero
for the remaining operations. The last three u32 fields are interpreted as follows:

| Operation | Offset 12 | Offset 16 | Offset 20 | Body |
| --- | --- | --- | --- | --- |
| 1: prepare | query bytes | 0 | pair count | query, then pairs |
| 2: align prepared | handle | target bytes | 0 | target |
| 3: release | handle | 0 | 0 | empty |
| 4: ordinary batch | job count | 0 | 0 | empty; followed by that many BED1 frames |
| 5: prepared batch | handle | target count | body bytes | repeated u32 length, then target bytes |
| 6: owned prepared input (optional) | handle | target bytes | 0 | target |
| 7: owned prepared batch (optional) | handle | target count | body bytes | repeated u32 length, then target bytes |
| 8: owned-input capabilities (optional) | 0 | 0 | 0 | empty |

Recognized operations 2 and 6 return BER1. Other operations return a 24-byte BER2 control frame:
magic `BER2`, operation, status (0 success, 1 rejected), handle, retained cache
budget bytes, result count; each field after magic is u32. Successful operations
4, 5 and 7 then return exactly result-count BER1 frames in input order. Empty
batches are valid. Invalid operation-2 handles/configurations return a BER1
ERROR; other rejected controls return BER2 with no following results.

CPU workers support optional operations 6/7 for unlimited NW DISTANCE. They use
owned packed byte buffers; operation 6 returns BER1, and operation 7 returns
BER2 followed by ordered BER1 results. Unsupported optional operations return
BER2 with status 1, handle 0 and count 0. `AlignmentWorker` selects them for
prepared queries of 1–128 bytes on current CPU workers. For queries above 64
bytes, it first sends operation 8 once per worker. Success returns the word width
in the control handle field and maximum supported query length in its count
field (currently 32 and 128). Explicit rejection preserves the 64-byte limit.
Operations 2/5 are used outside the advertised range or after explicit rejection
of operations 6/7. Negotiation and alignment share one deadline. GPU workers
reject these optional operations and use that fallback.

Preparation fixes the query, symmetric equality pairs, compact profile layout,
and 32-bit word width. Mode, task, threshold and CIGAR format remain per-call.
Prepared NW always profiles the prepared query, including when its target is
shorter. Empty-input exceptions and PATH coordinates retain ordinary semantics.
CPU workers use one workspace by default; sharded workers keep small byte
batches serial and move independent owners into balanced plans for larger jobs.
GPU prepared batches move independent owners into a balanced plan. Ordinary
batches use independent forks.
Use independently prepared workers or explicitly cloned Bend profiles for
concurrent shards. One worker never shares mutable workspace between calls.

Handles belong to one worker and expire on release or close. The cache admits
at most 32 entries and a 64 MiB conservative budget (twice buffer/term payload
bytes plus 4 KiB per entry); this is not process RSS. Prepare requests allow at
most 1 MiB of query bytes and 65,536 equality pairs. Batches allow at most 65,536
items. Admission failures preserve existing handles; release allows admission
again. BED1 sequence sizes retain their existing framing limit.

```python
with AlignmentWorker(["build/bend-edit-distance", *runtime_prefix(threads=1), "--worker"]) as worker:
    with worker.prepare(b"ACGT", (EqualityPair("N", "A"),)) as prepared:
        results = prepared.align_batch([b"ACGT", b"ACG", b"AACGT"])
        result = prepared.align(b"ACNT", AlignConfig(task=Task.PATH))
```

`worker.align_batch([(query, target, config), ...])` accepts mixed jobs.
`worker.retained_entries` and `worker.retained_bytes` expose cache admission
usage. Per-call equalities may be omitted or must equal the prepared definition.
Framing errors and timeouts close the worker and invalidate its handles without retry.
