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

def Laws.mask_case_sensitive():
  {==}

def Laws.mask_full_word_high_bit():
  {==}

def Laws.table_lookup_ascii():
  {==}

def Laws.table_lookup_missing():
  {==}

def Laws.block_match_carry():
  {==}

def Laws.block_mismatch_carry():
  {==}

def Laws.block_positive_carry():
  {==}

def Laws.block_decode_high_bit():
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

def Laws.cli_empty(remaining):
  {==}

def Laws.cli_no_capacity(h, tail):
  {==}

def Laws.cli_ascii_edges():
  {==}

def Laws.cli_non_ascii():
  {==}

def Laws.cli_empty_query_non_ascii():
  {==}

def Laws.cli_empty_target_non_ascii():
  {==}

def Laws.cli_nul():
  {==}

def Laws.cli_length_limit():
  {==}
