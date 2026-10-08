import Base
import ./LAWS.bend as Laws
import ./DistanceDP.bend as DP

def Laws.empty_query(target):
  {==}

def Laws.empty_target(query):
  match query:
    case SNil{}:
      {==}
    case SCon{h, t}:
      {==}

def Laws.wildcard_padding(symbol):
  {==}

def Laws.distance_empty():
  {==}

def Laws.distance_match():
  {==}

def Laws.distance_substitution():
  {==}

def Laws.distance_deletion():
  {==}

def Laws.distance_insertion():
  {==}

def Laws.distance_example():
  {==}

def Laws.dp_empty_query(target):
  {==}

def Laws.dp_empty_target(query):
  match query:
    case SNil{}:
      {==}
    case SCon{h, t}:
      {==}

def Laws.dp_row_width(length, column):
  match length:
    case 0n:
      {==}
    case 1n+p:
      %Laws.dp_row_width(p, U32.add(column, 1)) :
        {1n+List.length(&1, U32, DP.initial_row(p, U32.add(column, 1))) == 1n+_ : Nat}
      {==}

def Laws.dp_initial_row():
  {==}

def Laws.dp_cell(above, left, diagonal, row_symbol, column_symbol):
  {==}

def Laws.dp_next_row():
  {==}

def Laws.dp_match():
  {==}

def Laws.dp_substitution():
  {==}

def Laws.dp_deletion():
  {==}

def Laws.dp_insertion():
  {==}

def Laws.dp_example():
  {==}
