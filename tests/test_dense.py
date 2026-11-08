"""Forced full-width diagnostics stay independent of production dispatch."""

import itertools
import random
import subprocess

from alignment import AlignConfig, EqualityPair, MaxDistance
from benchmarks.gpu_runner import decode_batch
from bend_runtime import runtime_prefix
from tests.helpers import cpp_edlib_align
from tests.test_byte_band import band_probe
from tests.test_small_paths import distance_dp
from transport import encode_request

PAIRS = (EqualityPair(0, 255), EqualityPair(255, 128), EqualityPair(255, 0),
         EqualityPair(0, 255), EqualityPair('A', 'N'), EqualityPair('N', 'C'))


def probe(binary, query, target, config, mode='dense', count=26):
    done = subprocess.run([binary, *runtime_prefix(threads=1), mode],
        input=encode_request(query, target, config),
        capture_output=True, check=True, timeout=120)
    assert not done.stderr
    return [r.edit_distance for r in decode_batch(done.stdout, count)]


def check(binary, oracle, query, target, pairs=()):
    config = AlignConfig(equalities=pairs)
    optimum = (distance_dp(query, target, pairs) if max(len(query), len(target)) <= 300 else
               cpp_edlib_align(query, target, config, binary=oracle).edit_distance)
    for k in (None, max(0, optimum - 1), optimum, optimum + 1):
        options = config if k is None else AlignConfig(equalities=pairs, threshold=MaxDistance(k))
        values = probe(binary, query, target, options)
        assert values[:4] == values[4:8] == values[9:13] == values[13:17]
        assert values[8] == values[17] == 1
        assert values[0] == optimum
        assert values[1:4] == [((len(query) + 31) // 32) * len(target), len(target), 1]
        expected = optimum if k is None or optimum <= k else -1
        assert values[18] == expected
        assert values[22] == (optimum if not target else expected), (len(query), len(target), k, values)
        if k is not None and abs(len(query) - len(target)) > k and query and target:
            assert values[23:] == [0, 0, 0]


def test_forced_dense_exhaustive_and_every_remainder(band_probe, cpp_binary):
    tiny = [bytes(chars) for n in range(1, 4) for chars in itertools.product(b'\0\xff', repeat=n)]
    for query, target in itertools.product(tiny, repeat=2):
        for pairs in ((), PAIRS):
            check(band_probe, cpp_binary, query, target, pairs)
    rng = random.Random(39017)
    for length in (*range(1, 66), *range(129, 161), 95, 96, 97, 127, 128, 191, 192, 193, 255, 256, 257):
        query = bytes(rng.choices(b'ACN\0\x80\xff', k=length))
        targets = (b'', query, query[::-1], b'Z' * (length + 3), query[3:] + b'\xff')
        for target in targets:
            check(band_probe, cpp_binary, query, target, PAIRS)
        assert probe(band_probe, query, query[::-1], AlignConfig(equalities=PAIRS), 'dense-columns', 1) == [1]


def test_dense_large_partial_words_and_both_orientations(band_probe, cpp_binary):
    rng = random.Random(39319)
    for length in (4095, 4096, 4097, 65535, 65536, 65537):
        query = bytes(rng.choices(range(256), k=length))
        # Wide query, short target exercises every logical block without a
        # quadratic long-input test for every boundary/orientation.
        for target in (b'\0\x80\xff', bytes(range(65))):
            check(band_probe, cpp_binary, query, target, PAIRS)
            check(band_probe, cpp_binary, target, query, PAIRS)
    query = bytes(rng.choices(range(256), k=4097))
    for target in (query[65:] + query[:65], bytes(rng.choices(range(256), k=4100)),
                   b'Z' * 96 + query[96:], query[:2048] + b'Z' * 2049):
        check(band_probe, cpp_binary, query, target, PAIRS)
        assert probe(band_probe, query, target, AlignConfig(equalities=PAIRS), 'dense-columns', 1) == [1]
    query = bytes(range(256)) * 256
    target = query[:-1] + b'\0'
    check(band_probe, cpp_binary, query, target)


def test_dense_restart_resets_discarded_frontier_and_keeps_work(band_probe):
    rng = random.Random(39739)
    for length in (*range(129, 161), 1023, 1024, 1025, 4095, 4096, 4097):
        query = bytes(rng.choices(b'ACGT', k=length))
        for target in (query, bytes(rng.choices(b'ACGT', k=length)), b'Z' * length,
                       query[65:] + query[:65], b'Z' * 96 + query[96:]):
            values = probe(band_probe, query, target, AlignConfig(), 'dense-restart', 9)
            assert values[:4] == values[4:8] and values[8] == 1
            assert values[1] > ((length + 31) // 32) * len(target)
            assert values[2] > len(target) and values[3] == 2


def test_dense_all_bytes_and_nontransitive_masks(band_probe, cpp_binary):
    query = bytes(range(256)) * 2 + b'A\0'
    for pairs in ((), PAIRS, (*PAIRS, *reversed(PAIRS))):
        for target in (query[::-1], bytes(range(255, -1, -1)), b'\x80' * 513, b'C' * 513):
            check(band_probe, cpp_binary, query, target, pairs)


def test_dense_empty_exceptions_and_unchanged_fallback(band_probe):
    for query, target in ((b'', b''), (b'', b'\0\xff'), (b'ACN', b'')):
        for k in (0, 1, 3):
            values = probe(band_probe, query, target, AlignConfig(threshold=MaxDistance(k)), 'dense-public', 5)
            assert values[0] == values[4] == max(len(query), len(target))
            assert values[1:4] == [0, 0, 0]
    for length in (31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 1023, 1024, 1025):
        query = (bytes(range(256)) * 5)[:length]
        target = query[33:] + query[:33]
        for k in (0, 31, 32, 33, 64, length):
            values = probe(band_probe, query, target, AlignConfig(threshold=MaxDistance(k)), 'dense-fallback', 9)
            assert values[:4] == values[4:8] and values[8] == 1


def test_dense_arithmetic_bounds_and_reuse_after_dense(band_probe):
    assert probe(band_probe, b'A', b'A', AlignConfig(), 'dense-bounds', 8) == [1, 0, 0, 0, 1, 0, 1, 0]
    rng = random.Random(39971)
    for length in (129, 160, 257, 1023, 1024, 1025, 4095, 4096, 4097):
        query = bytes(rng.choices(b'ACGT', k=length))
        for target in (query, query[33:] + query[:33], b'Z' * length):
            values = probe(band_probe, query, target, AlignConfig(), 'dense-then-band', 9)
            assert values[:4] == values[4:8] and values[8] == 1
