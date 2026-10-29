import ./PathList.bend as PL
import Base
import ../EdlibTypes.bend as E
import ./Profile.bend as P

# Each cell packs a score in the high 30 bits and a two-bit predecessor.
# Filling owns one array; diagonal/left carry the sequential row dependency.
# Dimensions come from String.length and bound every row/column index. The
# caller checks score and allocation geometry before choosing this backend.
type Filling is Type:
  Filling{matrix: Array<U32>, diagonal: U32, left: U32}

def code(+above: U32, +left: U32, +diagonal: U32, +matches: Bool) -> U32:
  +up = U32.add(above, 1)
  +across = U32.add(left, 1)
  +diag = U32.add(diagonal, Bool.to_u32(Bool.not(matches)))
  Bool.pick(U32, U32.is_le(up, U32.min(across, diag)), U32.or(U32.shln(up, 2n), 1),
    Bool.pick(U32, U32.is_le(across, diag), U32.or(U32.shln(across, 2n), 2),
      U32.or(U32.shln(diag, 2n), U32.mul(3, Bool.to_u32(Bool.not(matches))))))

def initial(fuel: Nat, +index: U32, matrix: Array<U32>) -> Array<U32>:
  match fuel:
    case 0n:
      matrix
    case 1n+p:
      initial(p, U32.inc(index), matrix[index] <- U32.or(U32.shln(index, 2n), 2))

def calculated_cell(index: U32, diagonal: U32, left: U32, matches: Bool,
                      result: Array<U32> & U32) -> Filling:
  (matrix, bits) = result
  +above = U32.shrn(bits, 2n)
  +value = code(above, left, diagonal, matches)
  Filling{matrix[index] <- value, above, U32.shrn(value, 2n)}

def cells(columns: String, +symbol: Char, +pairs: List<&2, E.EqualityPair>,
            +index: U32, +base: U32, +stride: U32, state: Filling) -> Filling:
  match columns state:
    case SNil{} _:
      state
    case SCon{h, t} Filling{matrix, diagonal, left}:
      cells(t, symbol, pairs, U32.inc(index), base, stride,
        calculated_cell(U32.add(base, index), diagonal, left, E.equal(pairs, symbol, h),
          matrix[U32.add(U32.sub(base, stride), index)]))

def start_row(symbol: Char, columns: String, pairs: List<&2, E.EqualityPair>,
                +row: U32, +stride: U32, state: Filling) -> Filling:
  Filling{matrix, _, _} = state
  +base = U32.mul(row, stride)
  cells(columns, symbol, pairs, 1, base, stride,
    Filling{matrix[base] <- U32.or(U32.shln(row, 2n), 1), U32.sub(row, 1), row})

def rows(query: String, +target: String, +pairs: List<&2, E.EqualityPair>,
           +index: U32, +stride: U32, state: Filling) -> Filling:
  match query:
    case SNil{}:
      state
    case SCon{h, t}:
      rows(t, target, pairs, U32.inc(index), stride, start_row(h, target, pairs, index, stride, state))

def literal_cells(columns: String, +symbol: Char, +index: U32, +base: U32,
                    +stride: U32, state: Filling) -> Filling:
  match columns state:
    case SNil{} _:
      state
    case SCon{h, t} Filling{matrix, diagonal, left}:
      literal_cells(t, symbol, U32.inc(index), base, stride,
        calculated_cell(U32.add(base, index), diagonal, left, Char.is_eq(symbol, h),
          matrix[U32.add(U32.sub(base, stride), index)]))

def literal_start_row(symbol: Char, columns: String, +row: U32,
                        +stride: U32, state: Filling) -> Filling:
  Filling{matrix, _, _} = state
  +base = U32.mul(row, stride)
  literal_cells(columns, symbol, 1, base, stride,
    Filling{matrix[base] <- U32.or(U32.shln(row, 2n), 1), U32.sub(row, 1), row})

def literal_rows(query: String, +target: String, +index: U32,
                   +stride: U32, state: Filling) -> Filling:
  match query:
    case SNil{}:
      state
    case SCon{h, t}:
      literal_rows(t, target, U32.inc(index), stride, literal_start_row(h, target, index, stride, state))

def fill(query: String, target: String, pairs: List<&2, E.EqualityPair>,
           index: U32, stride: U32, state: Filling) -> Filling:
  match pairs:
    case Nil{}:
      literal_rows(query, target, index, stride, state)
    case _:
      rows(query, target, pairs, index, stride, state)

type Trace is Type:
  Finished{operations: List<&2, E.Operation>}
  Running{matrix: Array<U32>, row: U32, column: U32, operations: List<&2, E.Operation>}

def make_trace.chosen(matrix: Array<U32>, row: U32, column: U32,
                        operations: List<&2, E.Operation>, empty_row: Bool, empty_column: Bool) -> Trace:
  match empty_row empty_column:
    case True{} _:
      Finished{PL.repeat(U32.to_nat(column), E.Delete{}, operations)}
    case _ True{}:
      Finished{PL.repeat(U32.to_nat(row), E.Insert{}, operations)}
    case False{} False{}:
      Running{matrix, row, column, operations}

def make_trace(matrix: Array<U32>, +row: U32, +column: U32,
                  operations: List<&2, E.Operation>) -> Trace:
  make_trace.chosen(matrix, row, column, operations, U32.is_eq(row, 0), U32.is_eq(column, 0))

def moved(matrix: Array<U32>, row: U32, column: U32, operations: List<&2, E.Operation>,
             high: Bool, low: Bool) -> Trace:
  match high low:
    case False{} True{}:
      make_trace(matrix, U32.sub(row, 1), column, E.Insert{} <> operations)
    case True{} False{}:
      make_trace(matrix, row, U32.sub(column, 1), E.Delete{} <> operations)
    case False{} False{}:
      make_trace(matrix, U32.sub(row, 1), U32.sub(column, 1), E.Match{} <> operations)
    case True{} True{}:
      make_trace(matrix, U32.sub(row, 1), U32.sub(column, 1), E.Mismatch{} <> operations)

def read_trace(row: U32, column: U32, operations: List<&2, E.Operation>,
                 result: Array<U32> & U32) -> Trace:
  (matrix, +bits) = result
  moved(matrix, row, column, operations,
    U32.is_ne(U32.and(bits, 2), 0), U32.is_ne(U32.and(bits, 1), 0))

def trace(fuel: Nat, +stride: U32, state: Trace) -> List<&2, E.Operation>:
  match fuel state:
    case _ Finished{operations}:
      operations
    case 0n Running{_, _, _, operations}:
      operations
    case 1n+p Running{matrix, +row, +column, operations}:
      trace(p, stride, read_trace(row, column, operations, matrix[U32.add(U32.mul(row, stride), column)]))

def complete_into(+height: Nat, +width: Nat, stride: U32,
                      operations: List<&2, E.Operation>, state: Filling) -> List<&2, E.Operation>:
  Filling{matrix, _, _} = state
  trace(Nat.add(height, width), stride, make_trace(matrix, U32.from_nat(height), U32.from_nat(width), operations))

def complete(height: Nat, width: Nat, stride: U32, state: Filling) -> List<&2, E.Operation>:
  complete_into(height, width, stride, Nil{}, state)

def path_sized_into(query: String, +target: String, pairs: List<&2, E.EqualityPair>,
                      +height: Nat, +width: Nat, operations: List<&2, E.Operation>) -> List<&2, E.Operation>:
  +depth = P.depth(1n+width)
  +stride = U32.shln(1, depth)
  complete_into(height, width, stride, operations,
    fill(query, target, pairs, 1, stride,
      Filling{initial(1n+width, 0, Array.new(U32, Nat.add(P.depth(1n+height), depth), 0)), 0, 0}))

def path_sized(query: String, target: String, pairs: List<&2, E.EqualityPair>,
                 height: Nat, width: Nat) -> List<&2, E.Operation>:
  path_sized_into(query, target, pairs, height, width, Nil{})

# Bound logical cells including boundaries. Rounded dimensions use at most
# four times this storage; scores and indexes therefore fit their packed U32.
# Large one-row cases retain the list fallback.
def supported.product(height: Nat, width: Nat, bounded: Bool) -> Bool:
  match bounded:
    case False{}:
      False{}
    case True{}:
      Nat.is_le(Nat.mul(1n+height, 1n+width), 4096n)

def supported(+height: Nat, +width: Nat) -> Bool:
  supported.product(height, width,
    Bool.and(Nat.is_lt(height, 4096n), Nat.is_lt(width, 4096n)))

def score(cell: U32) -> U32:
  U32.shrn(cell, 2n)
