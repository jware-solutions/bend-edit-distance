"""Typed configuration and results shared by the Bend and Edlib adapters.

The wire formats use Edlib's integer sentinels. Public values distinguish
an unfound distance, a coordinate before zero, and an unrequested result.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, IntEnum
import json
import re


class Mode(Enum):
    NW = "NW"
    SHW = "SHW"
    HW = "HW"


class Task(Enum):
    DISTANCE = "DISTANCE"
    LOC = "LOC"
    PATH = "PATH"


class CigarFormat(Enum):
    STANDARD = "STANDARD"
    EXTENDED = "EXTENDED"


class Status(IntEnum):
    OK = 0
    ERROR = 1


class Operation(IntEnum):
    MATCH = 0
    INSERT = 1  # Insert into target; consumes query.
    DELETE = 2  # Delete from target; consumes target.
    MISMATCH = 3


def _nonnegative(value: int, name: str) -> None:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")


@dataclass(frozen=True)
class Unlimited:
    def to_edlib(self) -> int:
        return -1


@dataclass(frozen=True)
class MaxDistance:
    value: int

    def __post_init__(self) -> None:
        _nonnegative(self.value, "Maximum distance")
        if self.value > 2**31 - 1:
            raise ValueError("Maximum distance exceeds Edlib's int range")

    def to_edlib(self) -> int:
        return self.value


Threshold = Unlimited | MaxDistance


@dataclass(frozen=True)
class EqualityPair:
    first: int | bytes | str
    second: int | bytes | str

    def __post_init__(self) -> None:
        for value in (self.first, self.second):
            _byte(value)

    def to_bytes(self) -> bytes:
        return bytes((_byte(self.first), _byte(self.second)))


def _byte(value: int | bytes | str) -> int:
    if type(value) is int and 0 <= value <= 255:
        return value
    if isinstance(value, bytes) and len(value) == 1:
        return value[0]
    if isinstance(value, str) and len(value) == 1 and ord(value) <= 255:
        return ord(value)
    raise ValueError("Equality pairs require single byte values (0..255)")


@dataclass(frozen=True)
class AlignConfig:
    mode: Mode = Mode.NW
    task: Task = Task.DISTANCE
    threshold: Threshold = Unlimited()
    equalities: tuple[EqualityPair, ...] = ()
    cigar_format: CigarFormat = CigarFormat.EXTENDED

    def __post_init__(self) -> None:
        for value, expected in (
            (self.mode, Mode), (self.task, Task), (self.cigar_format, CigarFormat),
        ):
            if not isinstance(value, expected):
                raise TypeError(f"Expected {expected.__name__}, got {value!r}")
        if not isinstance(self.threshold, (Unlimited, MaxDistance)):
            raise TypeError("Expected Unlimited or MaxDistance threshold")
        if not isinstance(self.equalities, tuple) or not all(
            isinstance(p, EqualityPair) for p in self.equalities
        ):
            raise TypeError("Equalities must be a tuple of EqualityPair values")

    def argv(self) -> list[str]:
        """Optional legacy ASCII CLI; alignment workers use byte fields."""
        pairs = b"".join(p.to_bytes() for p in self.equalities)
        if len(pairs) > 4096 or b"\0" in pairs or not pairs.isascii():
            raise ValueError("Text CLI supports at most 2048 non-NUL ASCII equality pairs")
        return [
            "--config", self.mode.value, self.task.value, str(self.threshold.to_edlib()),
            pairs.decode("ascii"), self.cigar_format.value,
        ]


@dataclass(frozen=True)
class DistanceFound:
    value: int

    def __post_init__(self) -> None:
        _nonnegative(self.value, "Distance")

    def to_edlib(self) -> int:
        return self.value


@dataclass(frozen=True)
class DistanceNotFound:
    def to_edlib(self) -> int:
        return -1


EditDistance = DistanceFound | DistanceNotFound


@dataclass(frozen=True)
class BeforeStart:
    def to_edlib(self) -> int:
        return -1


@dataclass(frozen=True)
class Position:
    index: int

    def __post_init__(self) -> None:
        _nonnegative(self.index, "Position")

    def to_edlib(self) -> int:
        return self.index


Coordinate = BeforeStart | Position


def _wire_integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("Expected integer in alignment result")
    return value


def _coordinates(value: object) -> tuple[Coordinate, ...]:
    if not isinstance(value, list):
        raise ValueError("Expected location array")
    return tuple(BeforeStart() if _wire_integer(v) == -1 else Position(v) for v in value)


@dataclass(frozen=True)
class AlignResult:
    status: Status
    distance: EditDistance
    end_locations: tuple[Coordinate, ...]
    start_locations: tuple[Coordinate, ...] | None
    alignment: tuple[Operation, ...] | None
    cigar: str | None

    @property
    def edit_distance(self) -> int:
        """Edlib serialization; use distance for typed missing-value handling."""
        return self.distance.to_edlib()

    def to_edlib(self) -> dict[str, object]:
        return {
            "status": int(self.status), "edit_distance": self.edit_distance,
            "end_locations": [p.to_edlib() for p in self.end_locations],
            "start_locations": None if self.start_locations is None else [
                p.to_edlib() for p in self.start_locations
            ],
            "alignment": None if self.alignment is None else [int(op) for op in self.alignment],
            "cigar": self.cigar,
        }

    def require_distance(self) -> int:
        if self.status != Status.OK or not isinstance(self.distance, DistanceFound):
            raise ValueError("Alignment did not find a distance")
        return self.distance.value

    @classmethod
    def from_edlib(cls, value: object) -> AlignResult:
        try:
            keys = {
                "status", "edit_distance", "end_locations", "start_locations", "alignment", "cigar",
            }
            if not isinstance(value, dict) or set(value) != keys:
                raise ValueError("Expected complete alignment result object")
            status = Status(_wire_integer(value["status"]))
            distance_value = _wire_integer(value["edit_distance"])
            distance = DistanceNotFound() if distance_value == -1 else DistanceFound(distance_value)
            ends = _coordinates(value["end_locations"])
            starts = None if value["start_locations"] is None else _coordinates(
                value["start_locations"])
            ops = value["alignment"]
            if ops is not None and not isinstance(ops, list):
                raise ValueError("Expected operation array or null")
            alignment = None if ops is None else tuple(Operation(_wire_integer(op)) for op in ops)
            cigar = value["cigar"]
            if cigar is not None and (
                not isinstance(cigar, str) or re.fullmatch(r"(?:[1-9][0-9]*[MID=X])*", cigar) is None
            ):
                raise ValueError("Expected CIGAR string or null")
            if starts is not None and len(starts) != len(ends):
                raise ValueError("Expected matching start/end location counts")
            if (alignment is None) != (cigar is None):
                raise ValueError("Expected alignment and CIGAR to be present together")
            if status == Status.ERROR or isinstance(distance, DistanceNotFound):
                if distance_value != -1 or ends or starts is not None or alignment is not None:
                    raise ValueError("Expected absent results for error or missing distance")
            elif not ends:
                raise ValueError("Expected end locations for a found distance")
            return cls(status, distance, ends, starts, alignment, cigar)
        except (ValueError, TypeError, KeyError) as error:
            raise ValueError(f"Expected structured alignment result, got {value!r}: {error}") from error

    @classmethod
    def from_json(cls, output: str) -> AlignResult:
        """Text convenience layer outside the binary alignment transport."""
        try:
            return cls.from_edlib(json.loads(output))
        except (ValueError, TypeError) as error:
            raise ValueError(f"Expected structured alignment result, got {output!r}: {error}") from error
