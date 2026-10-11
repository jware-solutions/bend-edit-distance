import Base
import ./EdlibTypes.bend as E

# Independent Levenshtein distance with unit edit costs.
# Keep only the previous and current rows. NW uses min(m,n)+1 cells;
# directional modes retain target columns and use n+1 cells.
# The CLI caps each input at 4096 characters before calling either algorithm.

def initial_row(length: Nat, +column: U32) -> List<U32>:
  match length:
    case 0n:
      [column]
    case 1n+p:
      column <> initial_row(p, U32.add(column, 1))

# D[i,j] = min(D[i-1,j] + 1, D[i,j-1] + 1,
#              D[i-1,j-1] + !equal(pairs, row_symbol, column_symbol)).
def cell(above: U32, left: U32, diagonal: U32,
         row_symbol: Char, column_symbol: Char,
         pairs: List<&2, E.EqualityPair>) -> U32:
  U32.min(U32.min(U32.add(above, 1), U32.add(left, 1)),
    U32.add(diagonal, Bool.to_u32(Bool.not(E.equal(pairs, row_symbol, column_symbol)))))

# Consume the old row as the new row is built. The left/diagonal dependency
# makes adjacent cells sequential; copying a full matrix is unnecessary.
def row_cells(columns: String, previous: List<U32>, diagonal: U32,
              left: U32, +symbol: Char, +pairs: List<&2, E.EqualityPair>) -> List<U32>:
  match columns previous:
    case SNil{} _:
      Nil{}
    case SCon{h, t} Nil{}:
      Nil{}
    case SCon{h, t} +above <> rest:
      +next = cell(above, left, diagonal, symbol, h, pairs)
      next <> row_cells(t, rest, above, next, symbol, pairs)

def next_row(previous: List<U32>, columns: String, symbol: Char,
             +index: U32, pairs: List<&2, E.EqualityPair>) -> List<U32>:
  match previous:
    case Nil{}:
      [index]
    case diagonal <> rest:
      index <> row_cells(columns, rest, diagonal, index, symbol, pairs)

def last_cell(row: List<U32>) -> Nat:
  match row:
    case Nil{}:
      0n
    case value <> Nil{}:
      U32.to_nat(value)
    case _ <> rest:
      last_cell(rest)

def rows(sequence: String, +columns: String, previous: List<U32>,
         +index: U32, +pairs: List<&2, E.EqualityPair>) -> Nat:
  match sequence:
    case SNil{}:
      last_cell(previous)
    case SCon{h, t}:
      rows(t, columns, next_row(previous, columns, h, index, pairs), U32.add(index, 1), pairs)

def distance_shorter(query: String, target: String, query_length: Nat,
                     target_length: Nat, query_is_shorter: Bool,
                     pairs: List<&2, E.EqualityPair>) -> Nat:
  match query_is_shorter:
    case True{}:
      rows(target, query, initial_row(query_length, 0), 1, pairs)
    case False{}:
      rows(query, target, initial_row(target_length, 0), 1, pairs)

# Public entry point: importing this module does not import or call Myers.
def distance_with_equalities(query: String, target: String,
                             pairs: List<&2, E.EqualityPair>) -> Nat:
  match query target:
    case SNil{} _:
      String.length(target)
    case SCon{h, t} SNil{}:
      1n+String.length(t)
    case SCon{qh, qt} SCon{th, tt}:
      +q = {SCon{qh, qt} : String}
      +t = {SCon{th, tt} : String}
      +qn +tn = String.length(q) String.length(t)
      distance_shorter(q, t, qn, tn, Nat.is_le(qn, tn), pairs)

def distance(query: String, target: String) -> Nat:
  distance_with_equalities(query, target, Nil{})

# Directional DP keeps query rows and target columns in their original order.
# D[i,0] = i in every mode. SHW has D[0,j] = j and a free target suffix;
# HW has D[0,j] = 0 and both target ends free. Both minimize D[m,j].
def initial_semiglobal_row(length: Nat, +column: U32, +mode: E.Mode) -> List<U32>:
  match length mode:
    case 0n E.HW{}:
      [0]
    case 0n _:
      [column]
    case 1n+p E.HW{}:
      0 <> initial_semiglobal_row(p, U32.add(column, 1), mode)
    case 1n+p _:
      column <> initial_semiglobal_row(p, U32.add(column, 1), mode)

def final_row(query: String, +target: String, previous: List<U32>,
              +index: U32, +pairs: List<&2, E.EqualityPair>) -> List<U32>:
  match query:
    case SNil{}:
      previous
    case SCon{h, t}:
      final_row(t, target, next_row(previous, target, h, index, pairs), U32.add(index, 1), pairs)

type Best is Data:
  Best{score: U32, ends: List<&2, E.Coordinate>}

def collect_best(best: Best, score: U32, end: E.Coordinate, comparison: Cmp) -> Best:
  match best comparison:
    case _ LT{}:
      Best{score, [end]}
    case Best{old, ends} EQ{}:
      Best{old, end <> ends}
    case _ GT{}:
      best

def collect(cells: List<U32>, +index: Nat, +best: Best) -> Best:
  match cells:
    case Nil{}:
      best
    case +score <> tail:
      Best{old, _} = best
      collect(tail, 1n+index, collect_best(best, score, E.Position{index}, U32.cmp(score, old)))

def semiglobal_endpoints(cells: List<U32>, include_before: Bool) -> Best:
  match cells include_before:
    case Nil{} _:
      Best{0, Nil{}}
    case score <> tail True{}:
      collect(tail, 0n, Best{score, [E.BeforeStart{}]})
    case _ <> tail False{}:
      collect(tail, 0n, Best{4294967295, Nil{}})

def semiglobal(+query: String, +target: String, mode: E.Mode,
               pairs: List<&2, E.EqualityPair>) -> Best:
  # Pinned Edlib omits column zero when its final 64-bit word has no padding.
  qn tn = String.length(query) String.length(target)
  semiglobal_endpoints(final_row(query, target,
    initial_semiglobal_row(tn, 0, mode), 1, pairs), Nat.is_ne(Nat.mod(qn, 64n), 0n))

def semiglobal_result.accept(score: U32, ends: List<&2, E.Coordinate>, accepted: Bool) -> E.AlignResult:
  match accepted:
    case True{}:
      E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, List.reverse(&2, E.Coordinate, ends), None{}, None{}, None{}}
    case False{}:
      E.not_found()

def semiglobal_result(best: Best, +threshold: E.Threshold) -> E.AlignResult:
  match best:
    case Best{+score, ends}:
      semiglobal_result.accept(score, ends, E.within_threshold(threshold, U32.to_nat(score)))

# The independent worker supports configured DISTANCE in every mode, including
# Edlib's empty-input early return before threshold filtering.
def align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match query target config:
    case SNil{} +t E.AlignConfig{E.NW{}, E.Distance{}, _, _, _}:
      +length = String.length(t)
      E.distance_result(length, E.end_coordinate(length), True{})
    case SNil{} _ E.AlignConfig{_, E.Distance{}, _, _, _}:
      E.distance_result(0n, E.BeforeStart{}, True{})
    case SCon{_, qt} SNil{} E.AlignConfig{_, E.Distance{}, _, _, _}:
      E.distance_result(1n+String.length(qt), E.BeforeStart{}, True{})
    case +q +t E.AlignConfig{E.NW{}, E.Distance{}, +threshold, pairs, _}:
      +score = distance_with_equalities(q, t, pairs)
      E.distance_result(score, E.end_coordinate(String.length(t)), E.within_threshold(threshold, score))
    case +q +t E.AlignConfig{mode, E.Distance{}, threshold, pairs, _}:
      semiglobal_result(semiglobal(q, t, mode, pairs), threshold)
    case _ _ _:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}
