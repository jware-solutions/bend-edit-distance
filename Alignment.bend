import Base
import ./EdlibTypes.bend as E
import ./Reconstruction.bend as R

# Scalar reference locations use two score rows, without traceback prefixes.
# PATH reconstructs only the first interval with bounded DP / Hirschberg.
# The public API in main.bend uses Myers for all tasks' distances/ends and
# reverse SHW for HW starts.
type Cell is Data:
  Cell{score: U32, start: Nat}

type Location is Data:
  Location{end: E.Coordinate, start: Nat}

type Best is Data:
  Best{score: U32, locations: List<&2, Location>}

def extend(cell: Cell, cost: U32) -> Cell:
  match cell:
    case Cell{score, start}:
      Cell{U32.add(score, cost), start}

def prefer_cells(first: Cell, second: Cell, prefer: Bool) -> Cell:
  match prefer:
    case True{}:
      first
    case False{}:
      second

# Earliest optimal start reproduces Edlib's last reverse-SHW location.
# Equal starts retain above, left, diagonal priority.
def prefer(+first: Cell, +second: Cell) -> Cell:
  Cell{+a, sa} = first
  Cell{+b, sb} = second
  prefer_cells(first, second,
    Bool.or(U32.is_lt(a, b), Bool.and(U32.is_eq(a, b), Nat.is_le(sa, sb))))

def step(above: Cell, left: Cell, diagonal: Cell, matches: Bool) -> Cell:
  prefer(prefer(extend(above, 1), extend(left, 1)),
    extend(diagonal, Bool.to_u32(Bool.not(matches))))

def row_cells(columns: String, previous: List<&2, Cell>, diagonal: Cell,
              left: Cell, +symbol: Char, +pairs: List<&2, E.EqualityPair>) -> List<&2, Cell>:
  match columns previous:
    case SNil{} _:
      Nil{}
    case SCon{h, t} Nil{}:
      Nil{}
    case SCon{h, t} +above <> rest:
      +next = step(above, left, diagonal, E.equal(pairs, symbol, h))
      next <> row_cells(t, rest, above, next, symbol, pairs)

def next_row(previous: List<&2, Cell>, columns: String, symbol: Char,
             pairs: List<&2, E.EqualityPair>,
             +first: Cell) -> List<&2, Cell>:
  match previous:
    case Nil{}:
      [first]
    case diagonal <> rest:
      first <> row_cells(columns, rest, diagonal, first, symbol, pairs)

def initial_cell(mode: E.Mode, +index: U32) -> Cell:
  match mode:
    case E.HW{}:
      Cell{0, U32.to_nat(index)}
    case _:
      Cell{index, 0n}

def initial_row(columns: String, +mode: E.Mode, +index: U32) -> List<&2, Cell>:
  match columns:
    case SNil{}:
      [initial_cell(mode, index)]
    case SCon{_, t}:
      initial_cell(mode, index) <> initial_row(t, mode, U32.add(index, 1))

def rows(query: String, +columns: String, previous: List<&2, Cell>,
         +pairs: List<&2, E.EqualityPair>, +index: U32) -> List<&2, Cell>:
  match query:
    case SNil{}:
      previous
    case SCon{h, t}:
      rows(t, columns, next_row(previous, columns, h, pairs,
        Cell{index, 0n}), pairs, U32.add(index, 1))

def scores(query: String, +target: String, mode: E.Mode,
           pairs: List<&2, E.EqualityPair>) -> List<&2, Cell>:
  # Query rows and target columns must retain their orientation. D[i,0]=i;
  # D[0,j]=j for NW/SHW, and D[0,j]=0 for HW. SHW/HW free target suffixes
  # by minimizing the final query row instead of taking only its last cell.
  rows(query, target, initial_row(target, mode, 0), pairs, 1)

def last_cell(cells: List<&2, Cell>) -> Cell:
  match cells:
    case Nil{}:
      Cell{0, 0n}
    case cell <> Nil{}:
      cell
    case _ <> tail:
      last_cell(tail)

def update_best(best: Best, score: U32, location: Location, comparison: Cmp) -> Best:
  match best comparison:
    case Best{_, _} LT{}:
      Best{score, [location]}
    case Best{old, locations} EQ{}:
      Best{old, location <> locations}
    case _ GT{}:
      best

def collect(cells: List<&2, Cell>, +index: Nat, +best: Best) -> Best:
  match cells:
    case Nil{}:
      best
    case Cell{+score, start} <> tail:
      Best{old, _} = best
      collect(tail, 1n+index, update_best(best, score,
        Location{E.Position{index}, start}, U32.cmp(score, old)))

def ordered(best: Best) -> Best:
  match best:
    case Best{score, locations}:
      Best{score, List.reverse(&2, Location, locations)}

def nw_endpoint(cell: Cell, target_length: Nat) -> Best:
  match cell:
    case Cell{score, start}:
      Best{score, [Location{E.end_coordinate(target_length), start}]}

def semiglobal_endpoints(cells: List<&2, Cell>, include_before: Bool) -> Best:
  match cells include_before:
    case Nil{} _:
      Best{0, Nil{}}
    case Cell{score, start} <> tail True{}:
      ordered(collect(tail, 0n, Best{score, [Location{E.BeforeStart{}, start}]}))
    case _ <> tail False{}:
      ordered(collect(tail, 0n, Best{4294967295, Nil{}}))

def endpoints(cells: List<&2, Cell>, mode: E.Mode, target_length: Nat,
              query_length: Nat) -> Best:
  match cells mode:
    case _ E.NW{}:
      nw_endpoint(last_cell(cells), target_length)
    case _ _:
      # Pinned Edlib reports column zero through 64-bit wildcard padding.
      # With a full final word (W=0), it omits that end location.
      semiglobal_endpoints(cells, Nat.is_ne(Nat.mod(query_length, 64n), 0n))

def ends(locations: List<&2, Location>) -> List<&2, E.Coordinate>:
  match locations:
    case Nil{}:
      Nil{}
    case Location{end, _} <> tail:
      end <> ends(tail)

def starts(locations: List<&2, Location>) -> List<&2, E.Coordinate>:
  match locations:
    case Nil{}:
      Nil{}
    case Location{_, start} <> tail:
      E.Position{start} <> starts(tail)

def span(target: String, location: Location) -> String:
  match location:
    case Location{E.BeforeStart{}, _}:
      ""
    case Location{E.Position{index}, start}:
      String.drop(String.take(target, 1n+index), start)

def path_result(score: U32, +locations: List<&2, Location>,
                +operations: List<&2, E.Operation>, format: E.CigarFormat) -> E.AlignResult:
  E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations),
    Some{starts(locations)}, Some{operations}, Some{E.alignment_to_cigar(operations, format)}}

def location_valid(target: String, location: Location) -> Bool:
  match location:
    case Location{E.BeforeStart{}, start}:
      Nat.is_eq(start, 0n)
    case Location{E.Position{+end}, start}:
      Bool.and(Nat.is_lt(end, String.length(target)), Nat.is_le(start, 1n+end))

def path_checked(score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                  operations: List<&2, E.Operation>, valid: Bool) -> E.AlignResult:
  match valid:
    case True{}:
      path_result(score, locations, operations, format)
    case False{}:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}

def path_validate(query: String, segment: String, pairs: List<&2, E.EqualityPair>,
                   +score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                   +operations: List<&2, E.Operation>, valid_location: Bool) -> E.AlignResult:
  path_checked(score, locations, format, operations,
    Bool.and(valid_location, R.valid_path(query, segment, operations, pairs, U32.to_nat(score))))

def path_reconstruct(+query: String, +segment: String, +pairs: List<&2, E.EqualityPair>,
                      score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                      valid_location: Bool) -> E.AlignResult:
  path_validate(query, segment, pairs, score, locations, format,
    R.reconstruct(query, segment, pairs), valid_location)

def result(query: String, target: String, task: E.Task,
           pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
           best: Best, accepted: Bool) -> E.AlignResult:
  match task best accepted:
    case _ _ False{}:
      E.not_found()
    case E.Distance{} Best{score, locations} True{}:
      E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations), None{}, None{}, None{}}
    case E.Locations{} Best{score, +locations} True{}:
      E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations), Some{starts(locations)}, None{}, None{}}
    case E.Path{} Best{_, Nil{}} True{}:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}
    case E.Path{} Best{score, +location <> tail} True{}:
      +sequence = target
      path_reconstruct(query, span(sequence, location), pairs, score,
        location <> tail, format, location_valid(sequence, location))

def finish(query: String, target: String, task: E.Task,
           threshold: E.Threshold, pairs: List<&2, E.EqualityPair>,
           format: E.CigarFormat, +best: Best) -> E.AlignResult:
  Best{score, _} = best
  result(query, target, task, pairs, format, best,
    E.within_threshold(threshold, U32.to_nat(score)))

# Pinned Edlib returns before applying k or calculating starts/path on empty
# inputs, including PATH. Preserve that observable oracle behavior.
def align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match query target config:
    case SNil{} +t E.AlignConfig{E.NW{}, _, _, _, _}:
      +length = String.length(t)
      E.distance_result(length, E.end_coordinate(length), True{})
    case SNil{} _ _:
      E.distance_result(0n, E.BeforeStart{}, True{})
    case SCon{_, qt} SNil{} _:
      E.distance_result(1n+String.length(qt), E.BeforeStart{}, True{})
    case +q +t E.AlignConfig{+mode, task, threshold, +pairs, format}:
      qn tn = String.length(q) String.length(t)
      finish(q, t, task, threshold, pairs, format,
        endpoints(scores(q, t, mode, pairs), mode, tn, qn))
