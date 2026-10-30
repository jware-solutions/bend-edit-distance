"""Persistent CPU shards own independent reusable profiles and workspaces."""

import itertools
import subprocess

import pytest

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Task
from bend_runtime import runtime_prefix
from benchmarks.gpu_runner import decode_batch
from tests.helpers import ROOT, assert_valid_path, cpp_edlib_align, execute
from transport import AlignmentWorker, MAX_RETAINED_BYTES, encode_request


def worker(binary, threads, shards):
    return AlignmentWorker([binary, *runtime_prefix(threads=threads), "--worker", "--shards", str(shards)], cwd=ROOT)


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("shards", [1, 2, 4])
def test_pool_worker_configurations_and_reuse(bend_binary, cpp_binary, threads, shards):
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    with worker(bend_binary, threads, shards) as pooled:
        for query in (b"", b"\0", b"A\0\xffN" * 17, bytes(range(129))):
            targets = [b"", b"A", query, query[::-1], b"\0\xffNC" * 20,
                       query[:31], query[:32], query[:33], query]
            with pooled.prepare(query, pairs) as prepared:
                retained = pooled.retained_bytes
                for mode, task, format in itertools.product(Mode, Task, CigarFormat):
                    config = AlignConfig(mode, task, equalities=pairs, cigar_format=format)
                    expected = [pooled.align(query, target, config) for target in targets]
                    results = prepared.align_batch(targets, config)
                    assert results == expected
                    assert prepared.align_batch([], config) == []
                    assert prepared.align(targets[-1], config) == expected[-1]
                    for target, result in zip(targets, results):
                        oracle = cpp_edlib_align(query, target, config, binary=cpp_binary)
                        assert (result.status, result.distance, result.end_locations, result.start_locations) == (
                            oracle.status, oracle.distance, oracle.end_locations, oracle.start_locations)
                        assert_valid_path(query, target, config, result)
                    assert pooled.retained_bytes == retained
            assert prepared.released
        assert pooled.retained_entries == pooled.retained_bytes == 0


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_pool_mixed_lengths_rejections_and_index_gathering(bend_binary, threads):
    query = b"A\0\xffNC" * 13
    targets = [(query + bytes(range(256)))[:(i * 29) % 131] for i in range(257)]
    with worker(bend_binary, threads, 4) as pooled, pooled.prepare(query) as prepared:
        for mode, task, maximum in [(Mode.NW, Task.DISTANCE, 0), (Mode.NW, Task.PATH, 65),
                                    (Mode.HW, Task.LOC, 1), (Mode.SHW, Task.PATH, 65)]:
            config = AlignConfig(mode, task, MaxDistance(maximum))
            expected = [pooled.align(query, target, config) for target in targets]
            assert prepared.align_batch(targets, config) == expected
            assert prepared.align_batch(targets[::-1], config) == expected[::-1]


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_distance_leaf_padding_adaptive_retries_and_empty_exceptions(bend_binary, threads):
    pairs = (EqualityPair(0, 255), EqualityPair(255, 127))
    with worker(bend_binary, threads, 4) as pooled:
        for padding in range(32):
            query = bytes(range(96 - padding))
            edited = query[3:] + b"\xff\0N"
            targets = [edited, b"", query, bytes(reversed(query)), edited[:32], query * 2, edited]
            optimum = pooled.align(query, edited, AlignConfig(equalities=pairs)).edit_distance
            with pooled.prepare(query, pairs) as prepared:
                for maximum in [max(0, optimum - 1), optimum, optimum + 1, None]:
                    config = AlignConfig(equalities=pairs) if maximum is None else AlignConfig(
                        threshold=MaxDistance(maximum), equalities=pairs)
                    expected = [pooled.align(query, target, config) for target in targets]
                    assert prepared.align_batch(targets, config) == expected
                    assert prepared.align_batch(targets[:3], config) == expected[:3]
                assert prepared.align(query).edit_distance == 0
                assert prepared.align(b"", AlignConfig(threshold=MaxDistance(0))).edit_distance == len(query)


def test_pool_cache_limit_release_and_close(bend_binary):
    with worker(bend_binary, 4, 4) as pooled:
        entries = []
        for _ in range(33):
            try:
                entries.append(pooled.prepare(bytes(range(256)) * 256))
            except RuntimeError as error:
                assert "cache limit exceeded" in str(error)
                break
        else:
            pytest.fail("Pool cache did not enforce its admission limit")
        assert 0 < pooled.retained_entries == len(entries) <= 32
        assert pooled.retained_bytes <= MAX_RETAINED_BYTES
        assert entries[0].align(b"", timeout=30).edit_distance == 65536
        for prepared in entries:
            prepared.release()
        assert pooled.retained_entries == pooled.retained_bytes == 0
        remaining = pooled.prepare(b"A")
        assert remaining.align(b"A").edit_distance == 0
    assert remaining.released
    with pytest.raises(RuntimeError, match="closed"):
        remaining.align(b"A")


@pytest.mark.parametrize("shards", ["0", "3", "8", ""])
def test_pool_invalid_shards_and_literal_cli_inputs(bend_binary, shards):
    result = execute([bend_binary, *runtime_prefix(threads=1), "--worker", "--shards", shards], check=False)
    assert result.returncode == 2
    assert "Expected 1, 2 or 4" in result.stderr
    assert execute([bend_binary, *runtime_prefix(threads=1), "--worker", "4"]).stdout.strip() == "8"


@pytest.fixture(scope="module")
def pool_probe(bend_tool):
    binary = ROOT / "build" / "pool-probe"
    execute([bend_tool, ROOT / "tests/pool_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_public_pool_api_preserves_byte_and_generic_calls(pool_probe, threads):
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))
    for variant in ("byte", "both", "target"):
        for mode, task in itertools.product(Mode, Task):
            for query, target in [(b"\0A", b""), (b"A\0\xffN" * 9, b"N\0\xffA" * 10),
                                  (b"A\0\xffN" * 8, b"N\0\xffA" * 7)]:
                config = AlignConfig(mode, task, equalities=pairs)
                result = subprocess.run([pool_probe, *runtime_prefix(threads=threads), variant],
                    input=encode_request(query, target, config), capture_output=True, check=True, timeout=30)
                assert result.stderr == b""
                values = decode_batch(result.stdout, 10)
                assert values[:5] == values[5:]
