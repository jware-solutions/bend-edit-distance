import Base

# Independent NW/global Levenshtein distance with unit edit costs.
# Keep only the previous and current rows, each min(m, n) + 1 cells.
# The CLI caps each input at 4096 characters before calling either algorithm.

def initial_row(length: Nat, +column: U32) -> List<U32>:
  match length:
    case 0n:
      [column]
    case 1n+p:
      column <> initial_row(p, U32.add(column, 1))

# D[i,j] = min(D[i-1,j] + 1, D[i,j-1] + 1,
#              D[i-1,j-1] + (row_symbol != column_symbol)).
def cell(above: U32, left: U32, diagonal: U32,
         row_symbol: Char, column_symbol: Char) -> U32:
  U32.min(U32.min(U32.add(above, 1), U32.add(left, 1)),
    U32.add(diagonal, Bool.to_u32(Bool.not(Char.is_eq(row_symbol, column_symbol)))))

# Consume the old row as the new row is built. The left/diagonal dependency
# makes adjacent cells sequential; copying a full matrix is unnecessary.
def row_cells(columns: String, previous: List<U32>, diagonal: U32,
              left: U32, +symbol: Char) -> List<U32>:
  match columns previous:
    case SNil{} _:
      Nil{}
    case SCon{h, t} Nil{}:
      Nil{}
    case SCon{h, t} +above <> rest:
      +next = cell(above, left, diagonal, symbol, h)
      next <> row_cells(t, rest, above, next, symbol)

def next_row(previous: List<U32>, columns: String, symbol: Char,
             +index: U32) -> List<U32>:
  match previous:
    case Nil{}:
      [index]
    case diagonal <> rest:
      index <> row_cells(columns, rest, diagonal, index, symbol)

def last_cell(row: List<U32>) -> Nat:
  match row:
    case Nil{}:
      0n
    case value <> Nil{}:
      U32.to_nat(value)
    case _ <> rest:
      last_cell(rest)

def rows(sequence: String, +columns: String, previous: List<U32>,
         +index: U32) -> Nat:
  match sequence:
    case SNil{}:
      last_cell(previous)
    case SCon{h, t}:
      rows(t, columns, next_row(previous, columns, h, index), U32.add(index, 1))

def distance_shorter(query: String, target: String, query_length: Nat,
                     target_length: Nat, query_is_shorter: Bool) -> Nat:
  match query_is_shorter:
    case True{}:
      rows(target, query, initial_row(query_length, 0), 1)
    case False{}:
      rows(query, target, initial_row(target_length, 0), 1)

# Public entry point: importing this module does not import or call Myers.
def distance(query: String, target: String) -> Nat:
  match query target:
    case SNil{} _:
      String.length(target)
    case SCon{h, t} SNil{}:
      1n+String.length(t)
    case SCon{qh, qt} SCon{th, tt}:
      +q = {SCon{qh, qt} : String}
      +t = {SCon{th, tt} : String}
      +qn +tn = String.length(q) String.length(t)
      distance_shorter(q, t, qn, tn, Nat.is_le(qn, tn))
