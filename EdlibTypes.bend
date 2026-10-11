import Base

# Edlib sentinels are distinct constructors, never wrapped U32 values.
type Mode is Data:
  NW{}
  SHW{}
  HW{}

type Task is Data:
  Distance{}
  Locations{}
  Path{}

type Threshold is Data:
  Unlimited{}
  MaxDistance{value: Nat}

type EqualityPair is Data:
  EqualityPair{first: Char, second: Char}

type CigarFormat is Data:
  Standard{}
  Extended{}

type AlignConfig is Data:
  AlignConfig{mode: Mode, task: Task, threshold: Threshold,
    equalities: List<&2, EqualityPair>, cigar_format: CigarFormat}

type Status is Data:
  Ok{}
  Error{}

type EditDistance is Data:
  Found{value: Nat}
  NotFound{}

type Coordinate is Data:
  BeforeStart{}
  Position{index: Nat}

type Operation is Data:
  Match{}
  Insert{}
  Delete{}
  Mismatch{}

type AlignResult is Data:
  AlignResult{status: Status, distance: EditDistance,
    end_locations: List<&2, Coordinate>,
    start_locations: Maybe<&2, List<&2, Coordinate>>,
    alignment: Maybe<&2, List<&2, Operation>>, cigar: Maybe<&2, String>}

def default_config() -> AlignConfig:
  AlignConfig{NW{}, Distance{}, Unlimited{}, Nil{}, Extended{}}

# Literal equality plus explicitly configured symmetric pairs. Scanning the
# pairs never follows a chain, so shared endpoints do not imply transitivity.
def pair_matches(pair: EqualityPair, +a: Char, +b: Char) -> Bool:
  match pair:
    case EqualityPair{+first, +second}:
      Bool.or(Bool.and(Char.is_eq(a, first), Char.is_eq(b, second)),
        Bool.and(Char.is_eq(a, second), Char.is_eq(b, first)))

def equal(pairs: List<&2, EqualityPair>, +a: Char, +b: Char) -> Bool:
  match pairs:
    case Nil{}:
      Char.is_eq(a, b)
    case pair <> tail:
      Bool.or(pair_matches(pair, a, b), equal(tail, a, b))

def end_coordinate(length: Nat) -> Coordinate:
  match length:
    case 0n:
      BeforeStart{}
    case 1n+p:
      Position{p}

def distance_show(distance: EditDistance) -> String:
  match distance:
    case Found{value}:
      Nat.show(value)
    case NotFound{}:
      "-1"

def coordinate_show(position: Coordinate) -> String:
  match position:
    case BeforeStart{}:
      "-1"
    case Position{index}:
      Nat.show(index)

def status_show(status: Status) -> String:
  match status:
    case Ok{}:
      "0"
    case Error{}:
      "1"

def operation_show(operation: Operation) -> String:
  match operation:
    case Match{}:
      "0"
    case Insert{}:
      "1"
    case Delete{}:
      "2"
    case Mismatch{}:
      "3"

def operation_char(format: CigarFormat, operation: Operation) -> Char:
  match format operation:
    case _ Insert{}:
      'I'
    case _ Delete{}:
      'D'
    case Standard{} _:
      'M'
    case Extended{} Match{}:
      '='
    case Extended{} Mismatch{}:
      'X'

def cigar_step(rest: Unit -> String, symbol: Char, count: Nat, same: Bool) -> String:
  match same:
    case True{}:
      rest(Unit{})
    case False{}:
      Nat.show(count) ++ SCon{symbol, rest(Unit{})}

def cigar_runs(operations: List<&2, Operation>, +format: CigarFormat,
               +symbol: Char, +count: Nat) -> String:
  match operations:
    case Nil{}:
      Nat.show(count) ++ SCon{symbol, ""}
    case h <> t:
      +next = operation_char(format, h)
      cigar_step(_ => cigar_runs(t, format, next,
        Bool.pick(Nat, Char.is_eq(symbol, next), 1n+count, 1n)),
        symbol, count, Char.is_eq(symbol, next))

def alignment_to_cigar(operations: List<&2, Operation>, +format: CigarFormat) -> String:
  match operations:
    case Nil{}:
      ""
    case h <> t:
      cigar_runs(t, format, operation_char(format, h), 1n)

def coordinates_show(locations: List<&2, Coordinate>) -> String:
  List.show(~&2, ~Coordinate, ~coordinate_show, locations)

def starts_show(locations: Maybe<&2, List<&2, Coordinate>>) -> String:
  match locations:
    case None{}:
      "null"
    case Some{values}:
      coordinates_show(values)

def alignment_show(alignment: Maybe<&2, List<&2, Operation>>) -> String:
  match alignment:
    case None{}:
      "null"
    case Some{operations}:
      List.show(~&2, ~Operation, ~operation_show, operations)

# CIGAR contains only decimal counts and MID=X, so needs no JSON escaping.
def cigar_show(cigar: Maybe<&2, String>) -> String:
  match cigar:
    case None{}:
      "null"
    case Some{value}:
      "\"" ++ value ++ "\""

def result_show(result: AlignResult) -> String:
  match result:
    case AlignResult{status, distance, ends, starts, alignment, cigar}:
      "{\"status\":" ++ status_show(status) ++
      ",\"edit_distance\":" ++ distance_show(distance) ++
      ",\"end_locations\":" ++ coordinates_show(ends) ++
      ",\"start_locations\":" ++ starts_show(starts) ++
      ",\"alignment\":" ++ alignment_show(alignment) ++
      ",\"cigar\":" ++ cigar_show(cigar) ++ "}"

def not_found() -> AlignResult:
  AlignResult{Ok{}, NotFound{}, Nil{}, None{}, None{}, None{}}

def within_threshold(threshold: Threshold, distance: Nat) -> Bool:
  match threshold:
    case Unlimited{}:
      True{}
    case MaxDistance{maximum}:
      Nat.is_le(distance, maximum)

def distance_result(distance: Nat, end: Coordinate, accepted: Bool) -> AlignResult:
  match accepted:
    case True{}:
      AlignResult{Ok{}, Found{distance}, [end], None{}, None{}, None{}}
    case False{}:
      not_found()
