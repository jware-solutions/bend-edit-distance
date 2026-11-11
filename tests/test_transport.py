"""Byte alignment results and differential comparisons against Edlib."""

from bend_runtime import runtime_prefix

import itertools

import pytest
from hypothesis import given, settings, strategies as st

from alignment import AlignConfig, AlignResult, BeforeStart, CigarFormat, DistanceFound, EqualityPair, MaxDistance, Mode, Operation, Position, Status, Task
from transport import AlignmentWorker
from tests.helpers import ROOT, bend_align, bend_distance, bend_dp_distance, cpp_edlib_align


@pytest.mark.parametrize("distance", [0, 1, 2**31 - 1])
@pytest.mark.parametrize("end", [-1, 0, 2**31 - 1])
def test_distance_frame_keeps_typed_endpoint_and_absent_fields(distance, end):
    import struct
    from transport import RESPONSE, NULL_LENGTH, decode_response
    payload = RESPONSE.pack(b"BER1", 0, distance, 1, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH)
    value = decode_response(payload + struct.pack("<i", end))
    assert value == AlignResult(Status.OK, DistanceFound(distance),
        (BeforeStart() if end == -1 else Position(end),), None, None, None)


@pytest.mark.parametrize("field,value", [(0, b"BER2"), (1, 1), (1, 2), (2, -1), (2, -2),
    (3, 0), (3, 2), (3, 2**32 - 1), (4, 0), (4, 1), (5, 0), (5, 1), (6, 0), (6, 1)])
def test_distance_frame_rejects_invalid_common_shape(field, value):
    import struct
    from transport import RESPONSE, NULL_LENGTH, decode_response
    header = [b"BER1", 0, 1, 1, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH]
    header[field] = value
    payload = RESPONSE.pack(*header) + struct.pack("<i", 3)
    with pytest.raises(ValueError):
        decode_response(payload)


def test_distance_frame_rejects_truncation_trailing_bytes_and_negative_endpoint():
    import struct
    from transport import RESPONSE, NULL_LENGTH, decode_response
    header = RESPONSE.pack(b"BER1", 0, 1, 1, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH)
    payload = header + struct.pack("<i", 0)
    for malformed in [*(payload[:i] for i in range(len(payload))), payload + b"\0",
                      header + struct.pack("<i", -2)]:
        with pytest.raises(ValueError):
            decode_response(malformed)


def test_nondefault_frames_preserve_empty_fields_ties_and_rejection():
    import struct
    from alignment import DistanceNotFound
    from transport import RESPONSE, NULL_LENGTH, decode_response
    empty_path = RESPONSE.pack(b"BER1", 0, 0, 1, 1, 0, 0) + struct.pack("<ii", -1, 0)
    assert decode_response(empty_path) == AlignResult(
        Status.OK, DistanceFound(0), (BeforeStart(),), (Position(0),), (), "")
    tied = RESPONSE.pack(b"BER1", 0, 1, 3, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH)
    assert decode_response(tied + struct.pack("<iii", -1, 2, 2)).end_locations == (
        BeforeStart(), Position(2), Position(2))
    for status in Status:
        missing = RESPONSE.pack(b"BER1", status, -1, 0, NULL_LENGTH, NULL_LENGTH, NULL_LENGTH)
        assert decode_response(missing) == AlignResult(status, DistanceNotFound(), (), None, None, None)


@pytest.fixture(params=["bend_binary", "cpp_binary"])
def command(request):
    binary = request.getfixturevalue(request.param)
    runtime = runtime_prefix(threads=1) if request.param == "bend_binary" else []
    return [binary, *runtime, "--worker"]


@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("format", list(CigarFormat))
def test_configured_raw_bytes(bend_binary, cpp_binary, mode, task, format):
    query, target = b"\0\x80\xffA", b"\xff\0\x80BA\0"
    config = AlignConfig(mode, task, equalities=(EqualityPair(255, b"\0"),
                                                EqualityPair("A", b"B")), cigar_format=format)
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


@pytest.mark.parametrize("threads", [1, 2, 4])
def test_all_256_values(bend_binary, dp_binary, cpp_binary, threads):
    alphabet = bytes(range(256))
    # Every symbol is exercised as both query and target, without text decoding.
    assert bend_distance(alphabet, alphabet, binary=bend_binary, threads=threads) == 0
    target = alphabet[1:] + alphabet[:1]
    assert bend_dp_distance(alphabet, target, binary=dp_binary, threads=threads) == 2
    config = AlignConfig(task=Task.PATH)
    assert bend_align(alphabet, alphabet, config, binary=bend_binary, threads=threads) == cpp_edlib_align(
        alphabet, alphabet, config, binary=cpp_binary)
    assert bend_distance(alphabet, target, binary=bend_binary, threads=threads) == cpp_edlib_align(
        alphabet, target, binary=cpp_binary).require_distance() == 2


def test_exceeds_argument_length_limit(command):
    # Long inputs with an empty target have a known linear-cost alignment.
    sequence = bytes(range(256)) * 600
    with AlignmentWorker(command, cwd=ROOT) as worker:
        result = worker.align(sequence, b"")
        assert result == AlignResult(Status.OK, DistanceFound(len(sequence)),
                                     (BeforeStart(),), None, None, None)
        assert worker.align(b"A\0B", b"A\0B").require_distance() == 0


@pytest.mark.parametrize("query", [b"\0\xc0\xaf\x80\xff", b"\xc2\xa0\xe2\x82\xac\xf0\x9f\x98\x80",
                                  bytes(range(256)) * 21])
def test_raw_bridge_preserves_utf8_like_byte_lengths(bend_binary, query):
    with AlignmentWorker([bend_binary, *runtime_prefix(threads=1), "--worker"], cwd=ROOT) as worker:
        assert worker.align(query, b"").require_distance() == len(query)
        with worker.prepare(query) as prepared:
            expected = [worker.align(query, target) for target in (b"", query, query[1:], b"\0\xff")]
            assert prepared.align_batch([b"", query, query[1:], b"\0\xff"]) == expected


def test_worker_bypasses_text_sequence_and_equality_caps(command):
    with AlignmentWorker(command, cwd=ROOT) as worker:
        query = b"\0\x80\xff" * 1400
        assert worker.align(query, b"\0").require_distance() == len(query) - 1
        config = AlignConfig(task=Task.PATH, threshold=MaxDistance(2**31 - 1),
                             equalities=(EqualityPair(0, 255),) * 2050)
        assert worker.align(b"\0", b"\xff", config) == AlignResult(
            Status.OK, DistanceFound(0), (Position(0),), (Position(0),),
            (Operation.MATCH,), "1=")


@settings(max_examples=100, deadline=None, derandomize=True)
@given(query=st.binary(max_size=40), target=st.binary(max_size=40),
       mode=st.sampled_from(list(Mode)), task=st.sampled_from(list(Task)),
       maximum=st.integers(min_value=0, max_value=40),
       pairs=st.lists(st.tuples(st.integers(0, 255), st.integers(0, 255)), max_size=4))
def test_byte_differential(bend_binary, cpp_binary, query, target, mode, task, maximum, pairs):
    config = AlignConfig(mode, task, MaxDistance(maximum), tuple(EqualityPair(*p) for p in pairs))
    assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
        query, target, config, binary=cpp_binary)


@pytest.mark.alignment
def test_exhaustive_byte_domain(bend_binary, cpp_binary):
    sequences = [bytes(s) for n in range(3) for s in itertools.product((0, 128, 255), repeat=n)]
    for query, target, mode, task in itertools.product(sequences, sequences, Mode, Task):
        config = AlignConfig(mode, task)
        assert bend_align(query, target, config, binary=bend_binary) == cpp_edlib_align(
            query, target, config, binary=cpp_binary), (query, target, config)
