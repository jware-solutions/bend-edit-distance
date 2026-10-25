"""CIGAR encoding and decoded semantics, independent of traceback tie choices."""

from bend_runtime import runtime_prefix

from dataclasses import replace
import json

import pytest
from hypothesis import given, settings, strategies as st

from alignment import AlignConfig, CigarFormat, EqualityPair, MaxDistance, Mode, Operation, Task
from tests.helpers import assert_valid_cigar, assert_valid_path, bend_align, cpp_edlib_align, execute
from tests.test_reconstruction import probe_align


def encode(cigar_probe, operations, threads=1):
    codes = "".join(str(int(op)) for op in operations)
    output = execute([cigar_probe, *runtime_prefix(threads=threads), codes]).stdout
    standard, extended = json.loads(output)
    return {CigarFormat.STANDARD: standard, CigarFormat.EXTENDED: extended}


@pytest.mark.parametrize("threads", [1, 2, 4])
@pytest.mark.parametrize("codes,standard,extended", [
    ("", "", ""),
    ("0", "1M", "1="), ("1", "1I", "1I"),
    ("2", "1D", "1D"), ("3", "1M", "1X"),
    ("0003330011122203", "8M3I3D2M", "3=3X2=3I3D1=1X"),
    ("030303", "6M", "1=1X1=1X1=1X"),
    ("112211", "2I2D2I", "2I2D2I"),
    ("0" * 123 + "3" * 12 + "1" * 10 + "2" * 11,
     "135M10I11D", "123=12X10I11D"),
    ("03" * 4096, "8192M", "1=1X" * 4096),
    ("1" * 10000, "10000I", "10000I"),
])
def test_direct_encoding(cigar_probe, threads, codes, standard, extended):
    actual = encode(cigar_probe, tuple(Operation(int(c)) for c in codes), threads)
    assert actual == {CigarFormat.STANDARD: standard, CigarFormat.EXTENDED: extended}


@settings(max_examples=100, deadline=None, derandomize=True)
@given(operations=st.lists(st.sampled_from(list(Operation)), max_size=256))
def test_arbitrary_paths_decode_to_original_operations_and_cost(cigar_probe, operations):
    # Construct valid byte sequences for the supplied path. Configured equality
    # makes MATCH nonliteral; N=A and N=C must still leave A/C a MISMATCH.
    query, target = bytearray(), bytearray()
    for operation in operations:
        if operation == Operation.MATCH:
            query.append(ord("N"))
            target.append(ord("A"))
        elif operation == Operation.MISMATCH:
            query.append(ord("A"))
            target.append(ord("C"))
        elif operation == Operation.INSERT:
            query.append(0)
        else:
            target.append(255)
    pairs = (EqualityPair("N", "A"), EqualityPair("N", "C"))
    cost = sum(op != Operation.MATCH for op in operations)
    for format, cigar in encode(cigar_probe, operations).items():
        config = AlignConfig(task=Task.PATH, equalities=pairs, cigar_format=format)
        assert assert_valid_cigar(bytes(query), bytes(target), config, cigar, cost) == tuple(operations)


@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("threads", [1, 4])
@pytest.mark.parametrize("query,target", [
    (b"ACGT", b"AGGT"),
    (b"ACGT" * 40, b"AGCT" * 39),  # Divide-and-conquer may choose a different tie.
    (b"A" * 130, b"A" * 128),
    (b"NNAC", b"ACAC"),
    (b"a\0\x80NC" * 16, b"A\xff\x7fAC" * 15),
])
def test_public_cigar_consumption_and_cost(bend_binary, cpp_binary, format, mode, threads, query, target):
    pairs = (EqualityPair("a", "A"), EqualityPair("N", "A"), EqualityPair("N", "C"),
             EqualityPair(0, 255), EqualityPair(128, 127))
    config = AlignConfig(mode, Task.PATH, equalities=pairs, cigar_format=format)
    actual = bend_align(query, target, config, binary=bend_binary, threads=threads)
    expected = cpp_edlib_align(query, target, config, binary=cpp_binary)
    assert (actual.status, actual.distance, actual.start_locations, actual.end_locations) == (
        expected.status, expected.distance, expected.start_locations, expected.end_locations)
    assert_valid_path(query, target, config, actual)
    assert_valid_path(query, target, config, expected)
    # Choosing a CIGAR alphabet must not change reconstruction or locations.
    other_format = CigarFormat.STANDARD if format == CigarFormat.EXTENDED else CigarFormat.EXTENDED
    other = bend_align(query, target, replace(config, cigar_format=other_format),
                       binary=bend_binary, threads=threads)
    assert replace(other, cigar=actual.cigar) == actual


@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("query,target,pairs,cigar", [
    (b"aN", b"AA", (EqualityPair("a", "A"), EqualityPair("N", "A")), "2="),
    (b"AA", b"aN", (EqualityPair("a", "A"), EqualityPair("N", "A")), "2="),
    (b"AC", b"NA", (EqualityPair("N", "A"), EqualityPair("N", "C")), "1=1X"),
    (b"\0\x80", b"\xff\x7f", (EqualityPair(0, 255), EqualityPair(128, 127)), "2="),
])
def test_equality_aware_diagonals(bend_binary, format, query, target, pairs, cigar):
    config = AlignConfig(task=Task.PATH, equalities=pairs, cigar_format=format)
    result = bend_align(query, target, config, binary=bend_binary)
    assert result.cigar == ("2M" if format == CigarFormat.STANDARD else cigar)
    assert_valid_path(query, target, config, result)


@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("query,target", [(b"", b""), (b"", b"AC"), (b"AC", b"")])
def test_reconstructed_empty_paths(reconstruction_probe, format, query, target):
    config = AlignConfig(task=Task.PATH, cigar_format=format)
    result = probe_align(reconstruction_probe, "auto", query, target, config)
    assert result.cigar == (f"{len(query)}I" if query else f"{len(target)}D" if target else "")
    assert_valid_path(query, target, config, result)


@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("query,target", [(b"", b""), (b"", b"AC"), (b"AC", b"")])
def test_public_empty_input_paths_are_absent(bend_binary, format, mode, query, target):
    result = bend_align(query, target, AlignConfig(mode, Task.PATH, cigar_format=format), binary=bend_binary)
    assert result.alignment is None and result.cigar is None


@pytest.mark.parametrize("format", list(CigarFormat))
@pytest.mark.parametrize("config", [AlignConfig(task=Task.DISTANCE), AlignConfig(task=Task.LOC),
                                    AlignConfig(task=Task.PATH, threshold=MaxDistance(0))])
def test_unrequested_or_rejected_paths_have_no_cigar(bend_binary, format, config):
    result = bend_align(b"A", b"B", replace(config, cigar_format=format), binary=bend_binary)
    assert result.alignment is None and result.cigar is None
