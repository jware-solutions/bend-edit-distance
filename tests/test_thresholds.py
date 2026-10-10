"""Observable k semantics, including pinned upstream's empty-input exception."""

import json
import struct
import subprocess

import pytest

from alignment import (
    AlignConfig, AlignResult, BeforeStart, DistanceFound, DistanceNotFound,
    MaxDistance, Mode, Position, Status, Task, Unlimited, threshold_from_edlib,
)
from tests.helpers import ROOT, bend_align, cpp_edlib_align, execute
from transport import LENGTH, decode_response, encode_request

EMPTY = json.loads((ROOT / "tests/regressions/upstream_empty.json").read_text())


@pytest.mark.parametrize("case", EMPTY["cases"], ids=lambda c: c["id"])
@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("maximum", [-1, 0, 1, 2])
def test_upstream_empty_fixtures(bend_binary, cpp_binary, case, task, maximum):
    config = AlignConfig(Mode(case["mode"]), task, threshold_from_edlib(maximum))
    end = BeforeStart() if case["end"] == -1 else Position(case["end"])
    expected = AlignResult(Status.OK, DistanceFound(case["distance"]), (end,), None, None, None)
    for align, binary in ((bend_align, bend_binary), (cpp_edlib_align, cpp_binary)):
        assert align(case["query"], case["target"], config, binary=binary) == expected


@pytest.mark.parametrize("task", list(Task))
@pytest.mark.parametrize("query,target,distance", [
    ("AC", "AC", 0), ("AC", "AG", 1), ("AC", "AGT", 2),
    ("A" * 33, "T" * 33, 33), ("A" * 65, "A" * 129, 64),
])
def test_nw_inclusive_threshold(bend_binary, cpp_binary, task, query, target, distance):
    for maximum in {0, max(0, distance - 1), distance, distance + 1, 2**31 - 1}:
        config = AlignConfig(task=task, threshold=MaxDistance(maximum))
        actual = bend_align(query, target, config, binary=bend_binary)
        assert actual == cpp_edlib_align(query, target, config, binary=cpp_binary)
        if maximum < distance:
            assert actual == AlignResult(Status.OK, DistanceNotFound(), (), None, None, None)
        else:
            assert actual.distance == DistanceFound(distance)


@pytest.mark.parametrize("maximum", [-1, -2, -32, -(2**31)])
@pytest.mark.parametrize("mode", list(Mode))
@pytest.mark.parametrize("task", list(Task))
def test_negative_k_cli_and_wire(bend_binary, cpp_binary, maximum, mode, task):
    config = AlignConfig(mode, task)
    assert threshold_from_edlib(maximum) == Unlimited()
    for binary, align, runtime in ((bend_binary, bend_align, ["--threads", "1", "--"]),
                                   (cpp_binary, cpp_edlib_align, [])):
        expected = align(b"AC", b"TACG", config, binary=binary)
        args = config.argv()
        args[3] = str(maximum)
        assert AlignResult.from_json(execute([binary, *runtime, *args, "AC", "TACG"]).stdout) == expected
        frame = bytearray(encode_request(b"AC", b"TACG", config))
        struct.pack_into("<i", frame, 12, maximum)
        result = subprocess.run([binary, *runtime, "--worker"], input=frame,
                                capture_output=True, cwd=ROOT, timeout=10)
        assert result.returncode == 0 and result.stderr == b""
        size = LENGTH.unpack_from(result.stdout)[0]
        assert len(result.stdout) == size + 4
        assert decode_response(result.stdout[4:]) == expected


@pytest.mark.parametrize("value", [True, "-1", -(2**31) - 1, 2**31])
def test_threshold_conversion_rejects_invalid_i32(value):
    with pytest.raises(ValueError):
        threshold_from_edlib(value)
