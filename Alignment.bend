import Base
import ./EdlibTypes.bend as E

# Configured alignment uses the scalar recurrence. Only two score rows are
# retained; PATH also carries persistent, shared operation prefixes. The
# DISTANCE API in main.bend uses Myers for NW, SHW and HW, including pairs.
type Cell is Data:
  Cell{score: U32, start: Nat, operations: List<&2, E.Operation>}

type Location is Data:
  Location{end: E.Coordinate, start: Nat}

type Best is Data:
  Best{score: U32, locations: List<&2, Location>}

def trace_step(operations: List<&2, E.Operation>, operation: E.Operation,
               tracing: Bool) -> List<&2, E.Operation>:
  match tracing:
    case False{}:
      Nil{}
    case True{}:
      operation <> operations

def extend(cell: Cell, cost: U32, operation: E.Operation, tracing: Bool) -> Cell:
  match cell:
    case Cell{score, start, operations}:
      Cell{U32.add(score, cost), start, trace_step(operations, operation, tracing)}

def prefer_cells(first: Cell, second: Cell, prefer: Bool) -> Cell:
  match prefer:
    case True{}:
      first
    case False{}:
      second

# Earliest optimal start reproduces Edlib's last reverse-SHW location.
# Equal starts retain above, left, diagonal priority for NW traceback.
def prefer(+first: Cell, +second: Cell) -> Cell:
  Cell{+a, sa, _} = first
  Cell{+b, sb, _} = second
  prefer_cells(first, second,
    Bool.or(U32.is_lt(a, b), Bool.and(U32.is_eq(a, b), Nat.is_le(sa, sb))))

def step(above: Cell, left: Cell, diagonal: Cell, +tracing: Bool,
         +matches: Bool) -> Cell:
  prefer(prefer(extend(above, 1, E.Insert{}, tracing),
    extend(left, 1, E.Delete{}, tracing)),
    extend(diagonal, Bool.to_u32(Bool.not(matches)),
      Bool.pick(E.Operation, matches, E.Match{}, E.Mismatch{}), tracing))

def row_cells(columns: String, previous: List<&2, Cell>, diagonal: Cell,
              left: Cell, +symbol: Char, +pairs: List<&2, E.EqualityPair>,
              +tracing: Bool) -> List<&2, Cell>:
  match columns previous:
    case SNil{} _:
      Nil{}
    case SCon{h, t} Nil{}:
      Nil{}
    case SCon{h, t} +above <> rest:
      +next = step(above, left, diagonal, tracing, E.equal(pairs, symbol, h))
      next <> row_cells(t, rest, above, next, symbol, pairs, tracing)

def next_row(previous: List<&2, Cell>, columns: String, symbol: Char,
             pairs: List<&2, E.EqualityPair>, tracing: Bool,
             +first: Cell) -> List<&2, Cell>:
  match previous:
    case Nil{}:
      [first]
    case diagonal <> rest:
      first <> row_cells(columns, rest, diagonal, first, symbol, pairs, tracing)

def initial_cell(+mode: E.Mode, +index: U32,
                 operations: List<&2, E.Operation>) -> Cell:
  match mode:
    case E.HW{}:
      Cell{0, U32.to_nat(index), Nil{}}
    case _:
      Cell{index, 0n, operations}

def initial_row(columns: String, +mode: E.Mode, +index: U32, +tracing: Bool,
                +operations: List<&2, E.Operation>) -> List<&2, Cell>:
  match columns:
    case SNil{}:
      [initial_cell(mode, index, operations)]
    case SCon{_, t}:
      initial_cell(mode, index, operations) <>
        initial_row(t, mode, U32.add(index, 1), tracing,
          trace_step(operations, E.Delete{}, tracing))

def rows(query: String, +columns: String, previous: List<&2, Cell>,
         +pairs: List<&2, E.EqualityPair>, +index: U32, +tracing: Bool,
         +operations: List<&2, E.Operation>) -> List<&2, Cell>:
  match query:
    case SNil{}:
      previous
    case SCon{h, t}:
      +path = trace_step(operations, E.Insert{}, tracing)
      rows(t, columns, next_row(previous, columns, h, pairs, tracing,
        Cell{index, 0n, path}), pairs, U32.add(index, 1), tracing, path)

def scores(query: String, +target: String, mode: E.Mode,
           pairs: List<&2, E.EqualityPair>, +tracing: Bool) -> List<&2, Cell>:
  # Query rows and target columns must retain their orientation. D[i,0]=i;
  # D[0,j]=j for NW/SHW, and D[0,j]=0 for HW. SHW/HW free target suffixes
  # by minimizing the final query row instead of taking only its last cell.
  rows(query, target, initial_row(target, mode, 0, tracing, Nil{}),
    pairs, 1, tracing, Nil{})

def last_cell(cells: List<&2, Cell>) -> Cell:
  match cells:
    case Nil{}:
      Cell{0, 0n, Nil{}}
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
    case Cell{+score, start, _} <> tail:
      Best{old, _} = best
      collect(tail, 1n+index, update_best(best, score,
        Location{E.Position{index}, start}, U32.cmp(score, old)))

def ordered(best: Best) -> Best:
  match best:
    case Best{score, locations}:
      Best{score, List.reverse(&2, Location, locations)}

def nw_endpoint(cell: Cell, target_length: Nat) -> Best:
  match cell:
    case Cell{score, start, _}:
      Best{score, [Location{E.end_coordinate(target_length), start}]}

def semiglobal_endpoints(cells: List<&2, Cell>, include_before: Bool) -> Best:
  match cells include_before:
    case Nil{} _:
      Best{0, Nil{}}
    case Cell{score, start, _} <> tail True{}:
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

def path_cell(score: U32, locations: List<&2, Location>, format: E.CigarFormat,
              cell: Cell) -> E.AlignResult:
  match cell:
    case Cell{_, _, operations}:
      path_result(score, locations, List.reverse(&2, E.Operation, operations), format)

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
    case E.Path{} Best{score, +locations} True{}:
      location = Maybe.default(&2, Location, List.head(&2, Location, locations),
        Location{E.BeforeStart{}, 0n})
      path_cell(score, locations, format,
        last_cell(scores(query, span(target, location), E.NW{}, pairs, True{})))

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
        endpoints(scores(q, t, mode, pairs, False{}), mode, tn, qn))
