"""Owned prepared queries, worker-local handles and ordered binary batches."""

import itertools
from dataclasses import replace

import pytest

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Task
from bend_runtime import runtime_prefix
from tests.helpers import ROOT, assert_valid_path, cpp_edlib_align
from transport import AlignmentWorker, MAX_RETAINED_BYTES


def worker(binary, threads=1):
    return AlignmentWorker([binary, *runtime_prefix(threads=threads), "--worker"], cwd=ROOT)


def check(actual, ordinary, expected, query, target, config):
    assert actual == ordinary
    assert (actual.status, actual.distance, actual.end_locations, actual.start_locations) == (
        expected.status, expected.distance, expected.end_locations, expected.start_locations)
    assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_prepared_configurations_and_different_targets(bend_binary, cpp_binary, threads):
    query = b"A\0\xffN" * 17
    pairs = (EqualityPair(0, 255), EqualityPair("A", "N"), EqualityPair("N", "C"))
    with worker(bend_binary, threads) as w, w.prepare(query, pairs) as prepared:
        for mode, task, format in itertools.product(Mode, Task, CigarFormat):
            config = AlignConfig(mode, task, equalities=pairs, cigar_format=format)
            for n in (0, 1, 31, 32, 33, 63, 64, 65, 97):
                target = (bytes(range(256)) + query * 2)[:n]
                actual = prepared.align(target, config)
                check(actual, w.align(query, target, config),
                    cpp_edlib_align(query, target, config, binary=cpp_binary), query, target, config)
        assert w.retained_entries == 1
        assert 0 < w.retained_bytes <= MAX_RETAINED_BYTES
    assert prepared.released


def test_prepared_padding_thresholds_and_retry_reset(bend_binary, cpp_binary):
    with worker(bend_binary) as w:
        for padding in range(32):
            query = (bytes(range(256)) * 2)[:96 - padding]
            pairs = (EqualityPair(0, 255), EqualityPair(255, 127))
            with w.prepare(query, pairs) as prepared:
                target = query[3:] + b"\xff\0N"
                for mode in Mode:
                    base = AlignConfig(mode=mode, equalities=pairs)
                    optimum = cpp_edlib_align(query, target, base, binary=cpp_binary).edit_distance
                    for config in (replace(base, threshold=MaxDistance(max(0, optimum - 1))),
                                   base, replace(base, threshold=MaxDistance(optimum)),
                                   replace(base, threshold=MaxDistance(optimum + 1))):
                        assert prepared.align(target, config) == w.align(query, target, config)
        assert w.retained_entries == w.retained_bytes == 0


@pytest.mark.parametrize("query,target", [(b"", b""), (b"", b"\0\xffAC"),
    (b"A" * 5001, b"A"), (bytes(range(256)), bytes(reversed(range(256))))])
def test_prepared_empty_long_and_byte_inputs(bend_binary, cpp_binary, query, target):
    with worker(bend_binary) as w, w.prepare(query) as prepared:
        for mode, task in itertools.product(Mode, Task):
            config = AlignConfig(mode, task, MaxDistance(0))
            actual = prepared.align(target, config, timeout=30)
            check(actual, w.align(query, target, config, timeout=30),
                cpp_edlib_align(query, target, config, binary=cpp_binary), query, target, config)
        path = AlignConfig(task=Task.PATH)
        actual = prepared.align(target, path, timeout=30)
        check(actual, w.align(query, target, path, timeout=30),
            cpp_edlib_align(query, target, path, binary=cpp_binary), query, target, path)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_worker_batches_keep_order_and_prepared_ownership(bend_binary, threads):
    jobs = [(b"AC" * (i % 5), b"CA" * (i % 7),
             AlignConfig(list(Mode)[i % 3], list(Task)[i % 3], MaxDistance(i % 4))) for i in range(24)]
    with worker(bend_binary, threads) as w:
        for values in ([], jobs[:1], jobs, jobs[::-1], jobs + jobs[:3]):
            assert w.align_batch(values) == [w.align(*job) for job in values]
        with w.prepare(b"AC" * 33) as prepared:
            targets = [b"", b"A", b"CA" * 64, b"AC" * 33, b"A", bytes(range(256))]
            for mode, task in itertools.product(Mode, Task):
                config = AlignConfig(mode, task)
                assert prepared.align_batch(targets, config) == [prepared.align(t, config) for t in targets]
                assert prepared.align_batch([], config) == []
            assert prepared.align(b"AC" * 33).edit_distance == 0


def test_worker_handle_ownership_release_and_close(bend_binary):
    with worker(bend_binary) as first, worker(bend_binary) as second:
        query = first.prepare(b"AN", [EqualityPair("A", "N")])
        with pytest.raises(ValueError, match="another worker"):
            second.align_prepared(query, b"AN")
        with pytest.raises(ValueError, match="fixed"):
            query.align(b"AN", AlignConfig(equalities=(EqualityPair("A", "C"),)))
        assert query.align(b"NN").edit_distance == 0
        assert query.release()
        assert not query.release()
        with pytest.raises(ValueError, match="released"):
            query.align(b"AN")
        other = first.prepare(b"A")
    assert other.released
    with pytest.raises(RuntimeError, match="closed"):
        other.align(b"A")


def test_worker_entry_and_byte_limits_are_recoverable(bend_binary):
    with worker(bend_binary) as w:
        entries = [w.prepare(b"A") for _ in range(32)]
        with pytest.raises(RuntimeError, match="cache limit"):
            w.prepare(b"A")
        old = entries.pop()
        old.release()
        new = w.prepare(b"A")
        assert new.handle != old.handle
        assert new.align(b"A").edit_distance == 0
        for entry in [*entries, new]:
            entry.release()
        assert w.retained_entries == w.retained_bytes == 0
        entries = []
        for _ in range(32):
            try:
                entries.append(w.prepare(bytes(range(256)) * 256))
            except RuntimeError as error:
                assert "cache limit" in str(error)
                break
        assert 0 < len(entries) < 32
        assert w.retained_bytes <= MAX_RETAINED_BYTES
        for entry in entries:
            entry.release()
        assert w.retained_entries == w.retained_bytes == 0
        assert w.align(b"A", b"A").edit_distance == 0


def test_cloned_profiles_have_independent_workspaces(bend_tool, bend_binary):
    from transport import LENGTH, decode_response, encode_request
    from tests.helpers import execute
    import subprocess

    binary = ROOT / "build" / "prepared-probe"
    execute([bend_tool, ROOT / "tests" / "prepared_probe.bend", "-o", binary], timeout=180)
    query = bytes(range(256)) * 2 + b"N"
    target = query[3:] + b"\0\xffAC"
    with worker(bend_binary) as ordinary:
        for threads, mode, task in itertools.product((1, 2, 4), Mode, Task):
            config = AlignConfig(mode, task, equalities=(EqualityPair(0, 255), EqualityPair("N", "A")))
            result = subprocess.run([binary, *runtime_prefix(threads=threads)],
                input=encode_request(query, target, config), capture_output=True, check=True, timeout=30)
            data = result.stdout
            values = []
            while data:
                size = LENGTH.unpack(data[:4])[0]
                values.append(decode_response(data[4:4 + size]))
                data = data[4 + size:]
            assert values == [ordinary.align(query, t, config) for t in (target, target[::-1])]
            assert result.stderr == b""
