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

# Each independent batch job keeps its own configuration and orientation.
type AlignJob is Data:
  AlignJob{query: String, target: String, config: AlignConfig}

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

# Encoded runs have positive counts and are merged after mapping to the selected
# alphabet: adjacent Match/Mismatch operations form one Standard M run.
type CigarRun is Data:
  CigarRun{count: Nat, symbol: Char}

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

# Literal matches do not depend on the configured equality pairs.
def equal.scan(pairs: List<&2, EqualityPair>, +a: Char, +b: Char) -> Bool:
  match pairs:
    case Nil{}:
      Char.is_eq(a, b)
    case pair <> tail:
      Bool.or(pair_matches(pair, a, b), equal.scan(tail, a, b))

def equal.literal(pair: EqualityPair, tail: List<&2, EqualityPair>,
                  +a: Char, +b: Char, same: Bool) -> Bool:
  match same:
    case True{}:
      True{}
    case False{}:
      Bool.or(pair_matches(pair, a, b), equal.scan(tail, a, b))

def equal(pairs: List<&2, EqualityPair>, +a: Char, +b: Char) -> Bool:
  match pairs:
    case Nil{}:
      Char.is_eq(a, b)
    case pair <> tail:
      equal.literal(pair, tail, a, b, Char.is_eq(a, b))

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

def cigar_run_step(runs: List<&2, CigarRun>, count: Nat, symbol: Char,
                   next: Char, same: Bool) -> List<&2, CigarRun>:
  match same:
    case True{}:
      CigarRun{1n+count, symbol} <> runs
    case False{}:
      CigarRun{1n, next} <> CigarRun{count, symbol} <> runs

# The current run depends on the preceding symbol, so this scan is sequential.
# Tail recursion keeps long homogeneous and alternating paths bounded in stack.
def alignment_runs_reversed(operations: List<&2, Operation>, +format: CigarFormat,
                             runs: List<&2, CigarRun>) -> List<&2, CigarRun>:
  match operations runs:
    case Nil{} _:
      runs
    case h <> t Nil{}:
      alignment_runs_reversed(t, format, [CigarRun{1n, operation_char(format, h)}])
    case h <> t CigarRun{count, +symbol} <> tail:
      +next = operation_char(format, h)
      alignment_runs_reversed(t, format,
        cigar_run_step(tail, count, symbol, next, Char.is_eq(symbol, next)))

def alignment_runs(operations: List<&2, Operation>, format: CigarFormat) -> List<&2, CigarRun>:
  List.reverse(&2, CigarRun, alignment_runs_reversed(operations, format, Nil{}))

def cigar_runs_show.reversed(runs: List<&2, CigarRun>, value: String) -> String:
  match runs:
    case Nil{}:
      value
    case CigarRun{count, symbol} <> tail:
      cigar_runs_show.reversed(tail, Nat.show(count) ++ SCon{symbol, value})

def cigar_runs_show(runs: List<&2, CigarRun>) -> String:
  cigar_runs_show.reversed(List.reverse(&2, CigarRun, runs), "")

def alignment_to_cigar(operations: List<&2, Operation>, format: CigarFormat) -> String:
  cigar_runs_show.reversed(alignment_runs_reversed(operations, format, Nil{}), "")

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

# Pinned Edlib's semiglobal column-zero convention is observable even when
# the internal bit-vector word width differs from Edlib's 64-bit build.
def consider_empty_prefix(length: Nat) -> Bool:
  Nat.is_ne(Nat.mod(length, 64n), 0n)
