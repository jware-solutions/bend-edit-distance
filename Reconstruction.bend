import Base
import ./EdlibTypes.bend as E
import ./DistanceDP.bend as DP

# Global reconstruction of one already selected target interval. Small DP
# stores a score and predecessor operation per cell, never path prefixes.
# Equal scores prefer up (Insert), left (Delete), then diagonal, as upstream
# traceback does. Hirschberg only promises an optimal path, not upstream ties.

def diagonal_operation(matches: Bool) -> E.Operation:
  Bool.pick(E.Operation, matches, E.Match{}, E.Mismatch{})

type TraceCell is Data:
  TraceCell{score: U32, operation: E.Operation}

def cell_score(cell: TraceCell) -> U32:
  match cell:
    case TraceCell{score, _}:
      score

def choose_operation(matches: Bool, up_is_best: Bool, left_is_best: Bool) -> E.Operation:
  match up_is_best left_is_best:
    case True{} _:
      E.Insert{}
    case False{} True{}:
      E.Delete{}
    case False{} False{}:
      diagonal_operation(matches)

def dp_cell(above: U32, left: U32, diagonal: U32, +matches: Bool) -> TraceCell:
  +up = U32.add(above, 1)
  +across = U32.add(left, 1)
  +diagonal_cost = U32.add(diagonal, Bool.to_u32(Bool.not(matches)))
  TraceCell{U32.min(U32.min(up, across), diagonal_cost),
    choose_operation(matches,
      U32.is_le(up, U32.min(across, diagonal_cost)), U32.is_le(across, diagonal_cost))}

def dp_row_cells(columns: String, previous: List<&2, TraceCell>, diagonal: U32,
                 left: U32, +symbol: Char, +pairs: List<&2, E.EqualityPair>) ->
                 List<&2, TraceCell>:
  match columns previous:
    case SNil{} _:
      Nil{}
    case SCon{_, _} Nil{}:
      Nil{}
    case SCon{h, t} TraceCell{+above, _} <> rest:
      +next = dp_cell(above, left, diagonal, E.equal(pairs, symbol, h))
      next <> dp_row_cells(t, rest, above, cell_score(next), symbol, pairs)

def dp_row(previous: List<&2, TraceCell>, columns: String, symbol: Char,
           +index: U32, pairs: List<&2, E.EqualityPair>) ->
           List<&2, TraceCell>:
  match previous:
    case Nil{}:
      [TraceCell{index, E.Insert{}}]
    case TraceCell{diagonal, _} <> rest:
      TraceCell{index, E.Insert{}} <>
        dp_row_cells(columns, rest, diagonal, index, symbol, pairs)

def dp_initial(target: String, +index: U32) -> List<&2, TraceCell>:
  match target:
    case SNil{}:
      [TraceCell{index, E.Delete{}}]
    case SCon{_, tail}:
      TraceCell{index, E.Delete{}} <> dp_initial(tail, U32.add(index, 1))

def dp_rows(query: String, +target: String, previous: List<&2, TraceCell>,
            +index: U32, +pairs: List<&2, E.EqualityPair>,
            directions: List<&2, List<&2, TraceCell>>) -> List<&2, List<&2, TraceCell>>:
  match query:
    case SNil{}:
      directions
    case SCon{h, t}:
      +row = dp_row(previous, target, h, index, pairs)
      dp_rows(t, target, row, U32.add(index, 1), pairs,
        List.reverse(&2, TraceCell, row) <> directions)

# Rows and their operations are reversed so left moves consume the current
# row directly. Entering the row above skips only its unused right suffix.
# Including boundary rows/columns handles all-insertion/deletion paths.
def traceback(fuel: Nat, current: List<&2, TraceCell>,
               previous: List<&2, List<&2, TraceCell>>, +width: Nat,
               +column: Nat, operations: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match fuel current previous:
    case 0n _ _:
      operations
    case 1n+p _ Nil{}:
      List.append(&2, E.Operation, List.replicate(E.Operation, column, E.Delete{}), operations)
    case 1n+p Nil{} _:
      operations
    case 1n+p TraceCell{_, E.Insert{}} <> _ row <> rest:
      traceback(p, List.drop(&2, TraceCell, row, Nat.sub(width, column)),
        rest, width, column, E.Insert{} <> operations)
    case 1n+p TraceCell{_, E.Delete{}} <> tail +rows:
      traceback(p, tail, rows, width, Nat.sub(column, 1n), E.Delete{} <> operations)
    case 1n+p TraceCell{_, operation} <> _ row <> rest:
      +next_column = Nat.sub(column, 1n)
      traceback(p, List.drop(&2, TraceCell, row, Nat.sub(width, next_column)),
        rest, width, next_column, operation <> operations)

def dp_trace(matrix: List<&2, List<&2, TraceCell>>, query_length: Nat,
              +target_length: Nat) -> List<&2, E.Operation>:
  match matrix:
    case Nil{}:
      Nil{}
    case row <> rest:
      traceback(Nat.add(query_length, target_length), row, rest,
        target_length, target_length, Nil{})

def dp(+query: String, +target: String, pairs: List<&2, E.EqualityPair>) -> List<&2, E.Operation>:
  qn +tn = String.length(query) String.length(target)
  +boundary = dp_initial(target, 0)
  dp_trace(dp_rows(query, target, boundary, 1, pairs,
    [List.reverse(&2, TraceCell, boundary)]), qn, tn)

# Bound the complete small matrix, including its boundary cells. A one-row
# problem is also a base case, with linear storage in the column width.
def small_matrix(query_length: Nat, +target_length: Nat) -> Bool:
  Nat.is_le(1n+query_length, Nat.div(4096n, 1n+target_length))

def score_row(query: String, +target: String, pairs: List<&2, E.EqualityPair>) -> List<U32>:
  DP.final_row(query, target, DP.initial_row(String.length(target), 0), 1, pairs)

type Split is Data:
  Split{index: Nat, score: U32}

def split_index(split: Split) -> Nat:
  match split:
    case Split{index, _}:
      index

def split_score(split: Split) -> U32:
  match split:
    case Split{_, score}:
      score

def split_update(index: Nat, score: U32, old_index: Nat, old_score: U32,
                  better: Bool) -> Split:
  match better:
    case True{}:
      Split{index, score}
    case False{}:
      Split{old_index, old_score}

# Forward[j] + reverse[n-j] is the cost through the midpoint at column j.
# Strict comparison keeps the first minimum; this is our deterministic split
# policy and is deliberately separate from upstream Hirschberg compatibility.
def split_column(forward: List<U32>, backward: List<U32>, +index: Nat,
                  +best_index: Nat, +best_score: U32) -> Nat:
  match forward backward:
    case Nil{} _:
      best_index
    case _ Nil{}:
      best_index
    case a <> at b <> bt:
      +score = U32.add(a, b)
      +next = split_update(index, score, best_index, best_score,
        U32.is_lt(score, best_score))
      split_column(at, bt, 1n+index, split_index(next), split_score(next))

def midpoint(left: String, right: String, +target: String,
               +pairs: List<&2, E.EqualityPair>) -> Nat:
  # Prepare recursive arguments before the fork. Passing String.reverse(...)
  # inside its second call drains the frontier in the pinned native runtime.
  reverse_query = String.reverse(right)
  reverse_target = String.reverse(target)
  forward backward =
    score_row(left, target, pairs)
    score_row(reverse_query, reverse_target, pairs)
  split_column(forward, List.reverse(&1, U32, backward), 0n, 0n, 4294967295)

# The fuel is the initial row length; every nonbase call halves that length.
# Score passes run in balanced parallel calls and are consumed before recursion.
# Subpaths are evaluated sequentially to bound live score storage even on many
# threads; the result lists themselves necessarily use O(m+n) space.
def divide(fuel: Nat, +query: String, +target: String, +query_length: Nat,
             +target_length: Nat, +pairs: List<&2, E.EqualityPair>, small: Bool) ->
             List<&2, E.Operation>:
  match fuel query target small:
    case _ SNil{} _ _:
      List.replicate(E.Operation, target_length, E.Delete{})
    case _ _ SNil{} _:
      List.replicate(E.Operation, query_length, E.Insert{})
    case 0n _ _ _:
      dp(query, target, pairs)
    case 1n+p SCon{_, SNil{}} _ _:
      dp(query, target, pairs)
    case 1n+p _ _ True{}:
      dp(query, target, pairs)
    case Succ{+p} _ _ False{}:
      +half = Nat.div(query_length, 2n)
      +left = String.take(query, half)
      +right = String.drop(query, half)
      +cut = midpoint(left, right, target, pairs)
      left_path = divide(p, left, String.take(target, cut), half, cut, pairs,
        small_matrix(half, cut))
      +right_length = Nat.sub(query_length, half)
      +right_width = Nat.sub(target_length, cut)
      right_path = divide(p, right, String.drop(target, cut), right_length, right_width, pairs,
        small_matrix(right_length, right_width))
      List.append(&2, E.Operation, left_path, right_path)

def transpose(operations: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match operations:
    case Nil{}:
      Nil{}
    case E.Insert{} <> tail:
      E.Delete{} <> transpose(tail)
    case E.Delete{} <> tail:
      E.Insert{} <> transpose(tail)
    case operation <> tail:
      operation <> transpose(tail)

def reconstruct_order(query: String, target: String, +query_length: Nat,
                        +target_length: Nat, pairs: List<&2, E.EqualityPair>,
                        small: Bool, query_is_taller: Bool) -> List<&2, E.Operation>:
  match small query_is_taller:
    case True{} _:
      dp(query, target, pairs)
    case False{} True{}:
      divide(query_length, query, target, query_length, target_length, pairs, False{})
    case False{} False{}:
      transpose(divide(target_length, target, query, target_length, query_length, pairs, False{}))

def reconstruct(+query: String, +target: String, pairs: List<&2, E.EqualityPair>) ->
                  List<&2, E.Operation>:
  +qn +tn = String.length(query) String.length(target)
  reconstruct_order(query, target, qn, tn, pairs, small_matrix(qn, tn), Nat.is_ge(qn, tn))

# Edlib codes: Match=0 consumes both, Insert=1 consumes query only,
# Delete=2 consumes target only, Mismatch=3 consumes both. Validation requires
# exact consumption, the configured (symmetric, nontransitive) predicate on
# every diagonal operation, and an edit cost equal to the reported distance.
def validate(operations: List<&2, E.Operation>, query: String, target: String,
               +pairs: List<&2, E.EqualityPair>, +expected: Nat, cost: Nat) -> Bool:
  match operations query target:
    case Nil{} SNil{} SNil{}:
      Nat.is_eq(cost, expected)
    case E.Match{} <> tail SCon{q, qt} SCon{t, tt}:
      Bool.and(E.equal(pairs, q, t), validate(tail, qt, tt, pairs, expected, cost))
    case E.Mismatch{} <> tail SCon{q, qt} SCon{t, tt}:
      Bool.and(Bool.not(E.equal(pairs, q, t)), validate(tail, qt, tt, pairs, expected, 1n+cost))
    case E.Insert{} <> tail SCon{_, qt} _:
      validate(tail, qt, target, pairs, expected, 1n+cost)
    case E.Delete{} <> tail _ SCon{_, tt}:
      validate(tail, query, tt, pairs, expected, 1n+cost)
    case _ _ _:
      False{}

def valid_path(query: String, target: String, operations: List<&2, E.Operation>,
                 pairs: List<&2, E.EqualityPair>, distance: Nat) -> Bool:
  validate(operations, query, target, pairs, distance, 0n)
