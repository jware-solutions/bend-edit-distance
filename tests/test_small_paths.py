"""Exact low-distance edit frontiers and their configured PATH integration."""

from dataclasses import replace
import itertools
import random

import pytest

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Task
from tests.helpers import assert_valid_path, bend_align, cpp_edlib_align
from tests.test_reconstruction import probe_align, assert_same_locations


PAIRS = (EqualityPair("A", "N"), EqualityPair("N", "C"), EqualityPair(0, 255))


def distance_dp(query, target, pairs):
    edges = {tuple(pair.to_bytes()) for pair in pairs}
    edges |= {(b, a) for a, b in edges}
    row = list(range(len(target) + 1))
    for i, a in enumerate(query, 1):
        current = [i]
        for j, b in enumerate(target, 1):
            current.append(min(row[j] + 1, current[-1] + 1,
                               row[j - 1] + (a != b and (a, b) not in edges)))
        row = current
    return row[-1]


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_bounded_frontiers_against_independent_dp(reconstruction_probe, threads):
    rng = random.Random(951)
    sequences = [bytes(q) for n in range(4) for q in itertools.product(b"ANC", repeat=n)]
    cases = list(itertools.product(sequences, repeat=2))
    for length in (0, 1, 31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 255, 256, 257, 512):
        query = bytes(rng.choices(b"ACN\0\x80\xff", k=length))
        edited = bytearray(query)
        if length:
            edited[length // 2] ^= 0x55
        cases.extend([(query, bytes(edited)), (query, b"Z" + bytes(edited)),
                      (query, bytes(edited)[1:]), (query, bytes(reversed(query)))])
    for query, target in cases:
        optimum = distance_dp(query, target, PAIRS)
        # Large random rows exercise the rejection bound without constructing
        # unnecessarily high-cost frontiers in this low-distance backend test.
        maxima = {max(0, optimum - 1), optimum, optimum + 1} if optimum <= 20 else {0, 16}
        for maximum in maxima:
            config = AlignConfig(task=Task.PATH, threshold=MaxDistance(maximum), equalities=PAIRS)
            result = probe_align(reconstruction_probe, "bounded", query, target, config, threads)
            assert result.edit_distance == (optimum if optimum <= maximum else -1)
            assert_valid_path(query, target, config, result)


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("mode", list(Mode))
def test_public_low_distance_paths_and_frontier_cutoff(bend_binary, cpp_binary, threads, mode):
    rng = random.Random(714)
    for length in (255, 256, 257, 512, 4097):
        query = bytes(rng.choices(b"ACGT", k=length))
        edited = bytearray(query)
        for index in rng.sample(range(length), 8):
            edited[index] = ord("Z")
        segments = [query[:length // 2] + b"Z" + query[length // 2:],
                    query[:length // 2] + query[length // 2 + 1:],
                    b"Z" + query[:-1], query[:-8] + b"Z" + query[-8:-1], bytes(edited)]
        for index, segment in enumerate(segments):
            target = (b"prefix" if mode == Mode.HW else b"") + segment
            if mode != Mode.NW:
                target += b"suffix"
            config = AlignConfig(mode, Task.PATH, cigar_format=list(CigarFormat)[index % 2])
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
            assert_same_locations(actual, expected)
            assert_valid_path(query, target, config, actual)
            accepted = replace(config, threshold=MaxDistance(expected.require_distance()))
            assert bend_align(query, target, accepted, binary=bend_binary, threads=threads) == actual
            rejected = replace(config, threshold=MaxDistance(expected.require_distance() - 1))
            assert bend_align(query, target, rejected, binary=bend_binary, threads=threads).edit_distance == -1
        for distance in (16, 17):
            query, target = b"A" * length, b"Z" * distance + b"A" * (length - distance)
            config = AlignConfig(mode, Task.PATH)
            result = bend_align(query, target, config, binary=bend_binary, threads=threads)
            expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
            assert_same_locations(result, expected)
            assert_valid_path(query, target, config, result)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_all_byte_paths_with_nontransitive_pairs(bend_binary, cpp_binary, threads):
    query = bytes(range(256)) * 2
    segments = [b"\xff" + query[:-1], query[:255] + query[256:], query[:256] + b"\0" + query[256:]]
    edited = bytearray(query)
    for index in (0, 31, 32, 63, 64, 255, 256, 511):
        edited[index] ^= 0x55
    segments.append(bytes(edited))
    for mode, format, segment in itertools.product(Mode, CigarFormat, segments):
        target = (b"before" if mode == Mode.HW else b"") + segment
        config = AlignConfig(mode, Task.PATH, equalities=PAIRS, cigar_format=format)
        actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
        expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
        assert_same_locations(actual, expected)
        assert_valid_path(query, target, config, actual)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_generic_inputs_keep_existing_reconstruction(reconstruction_probe, threads):
    query = b"ACGT" * 65
    targets = [b"Z" + query[:-1], query[:128] + b"Z" + query[128:], b"Z" + query[1:]]
    for target, suffix in itertools.product(targets, ("generic", "generic-pairs")):
        config = AlignConfig(task=Task.PATH, equalities=PAIRS)
        actual = probe_align(reconstruction_probe, "known-" + suffix, query, target, config, threads)
        expected = probe_align(reconstruction_probe, "auto-" + suffix, query, target, config, threads)
        assert actual == expected
