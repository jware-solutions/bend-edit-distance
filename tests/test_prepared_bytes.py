"""Owned packed inputs, exact word tails and optional protocol negotiation."""

import random
import subprocess
from pathlib import Path

import pytest

from alignment import AlignConfig, EqualityPair, Status
from benchmarks.gpu_runner import decode_batch
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, execute
from tests.test_cpu_pools import worker
from tests.test_small_paths import distance_dp
from transport import LENGTH, encode_control, encode_request


PAIRS = (EqualityPair("A", "N"), EqualityPair("N", "C"),
         EqualityPair(0, 255), EqualityPair(128, 255))


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_every_query_padding_and_packed_target_tail(bend_binary, threads):
    rng = random.Random(312)
    with worker(bend_binary, threads, 4) as pooled:
        for length in range(1, 65):
            query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
            targets = [bytes(rng.choices(range(256), k=n)) for n in range(10)]
            targets += [b"\0\x80\xff", b"\xff\0\x80\0\xff"]
            if length in (32, 64):
                targets += [bytes(range(256)) * 16 + b"\xff"]
            with pooled.prepare(query, PAIRS) as prepared:
                retained = pooled.retained_bytes
                results = prepared.align_batch(targets)
                for target, result in zip(targets, results):
                    assert result.edit_distance == distance_dp(query, target, PAIRS)
                    assert result.end_locations[0].to_edlib() == len(target) - 1
                assert prepared.align(targets[-1]) == results[-1]
                assert pooled._owned_supported == {6: True, 7: True}
                assert pooled.retained_bytes == retained


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_owned_partitions_preserve_order_and_reuse_idle_shards(bend_binary, threads):
    rng = random.Random(833)
    query = bytes(rng.choices(range(256), k=64))
    targets = [bytes(rng.choices(range(256), k=(index * 39) % 513)) for index in range(513)]
    targets += [b"\0\xff" * 50001, b"", targets[3]]
    with worker(bend_binary, threads, 4) as pooled, pooled.prepare(query, PAIRS) as prepared:
        config = AlignConfig(equalities=PAIRS)
        expected = pooled.align_batch([(query, t, config) for t in targets])
        retained = pooled.retained_bytes
        for values, want in [(targets, expected), (targets[:8], expected[:8]), ([], []),
                             (targets[::-1], expected[::-1]), (targets, expected)]:
            assert prepared.align_batch(values, timeout=30) == want
            assert pooled.retained_bytes == retained
        assert prepared.align(query).edit_distance == 0


@pytest.fixture(scope="module")
def packed_probe(bend_tool):
    binary = ROOT / "build" / "prepared-bytes-probe"
    execute([bend_tool, ROOT / "tests/prepared_bytes_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_pure_buffers_preserve_generic_query_and_pair_fallbacks(packed_probe, threads):
    for kind in ("byte", "query", "pairs"):
        for query in (b"A", b"\0" + bytes(range(32)), bytes(range(65))):
            for target in (b"", bytes(range(7)), query[::-1], b"\xff" * 4097):
                result = subprocess.run([packed_probe, *runtime_prefix(threads=threads), kind],
                    input=encode_request(query, target, AlignConfig(equalities=PAIRS)),
                    capture_output=True, check=True, timeout=30)
                packed, reference = decode_batch(result.stdout, 2)
                assert packed == reference
                assert result.stderr == b""


def test_invalid_array_lengths_fail_before_wrapping_and_preserve_owner(packed_probe):
    result = subprocess.run([packed_probe, *runtime_prefix(threads=1), "bounds"],
        input=encode_request(b"A", b"A", AlignConfig()), capture_output=True, check=True, timeout=30)
    values = decode_batch(result.stdout, 4)
    assert [value.status for value in values] == [Status.ERROR, Status.OK, Status.ERROR, Status.OK]
    assert [values[index].edit_distance for index in (1, 3)] == [0, 0]
    assert result.stderr == b""


def test_optional_operation_configuration_rejection_is_recoverable(bend_binary):
    from alignment import MaxDistance
    with worker(bend_binary, 1, 1) as pooled, pooled.prepare(b"A") as prepared:
        rejected = encode_control(6, handle=prepared.handle, body=b"A",
                                  config=AlignConfig(threshold=MaxDistance(0)))
        control = pooled._exchange(rejected, lambda deadline: pooled._control(deadline, 6), 10)
        assert control[0] == 1 and control[1] == control[3] == 0
        assert prepared.align(b"A").edit_distance == 0


def test_malformed_owned_batch_closes_worker_and_invalidates_handles(bend_binary):
    with worker(bend_binary, 1, 1) as pooled:
        prepared = pooled.prepare(b"A")
        body = LENGTH.pack(9) + b"bad"
        frame = encode_control(7, handle=prepared.handle, count=1, body=body, pairs=len(body))
        with pytest.raises(RuntimeError, match="closed stdout"):
            pooled._exchange(frame, lambda deadline: pooled._control(deadline, 7), 10)
        assert pooled.closed and prepared.released


@pytest.mark.skipif(not Path("/proc/self/status").exists(), reason="Requires Linux process memory accounting")
def test_owned_buffers_do_not_accumulate_across_batches(bend_binary):
    def resident(pid):
        text = Path(f"/proc/{pid}/status").read_text()
        return int(next(line.split()[1] for line in text.splitlines() if line.startswith("VmRSS:"))) * 1024

    rng = random.Random(994)
    query = bytes(rng.choices(range(256), k=64))
    targets = [bytes(rng.choices(range(256), k=512 + index % 5)) for index in range(256)]
    with worker(bend_binary, 4, 4) as pooled, pooled.prepare(query) as prepared:
        expected = prepared.align_batch(targets)
        for _ in range(32):
            assert prepared.align_batch(targets) == expected
        baseline = resident(pooled.pid)
        retained = pooled.retained_bytes
        for index in range(192):
            values, want = (targets, expected) if index % 2 else (targets[::-1], expected[::-1])
            assert prepared.align_batch(values) == want
        assert resident(pooled.pid) <= baseline + 8 * 1024 * 1024
        assert pooled.retained_bytes == retained
