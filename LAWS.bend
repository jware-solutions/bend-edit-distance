import Base
import ./main.bend as Main
import ./DistanceDP.bend as DP
import ./Cli.bend as CLI

# NW boundary conditions: deleting or inserting a whole sequence costs its
# length. These quantify over every string, rather than selected examples.
law empty_query:
  for target: String
  {Main.edlib_align("", target) == String.length(target) : Nat}

law empty_target:
  for query: String
  {Main.edlib_align(query, "") == String.length(query) : Nat}

# Query-profile padding must match every symbol, including a full empty word.
law wildcard_padding:
  for symbol: Char
  {Main.build_peq_word("", symbol, 1) == 4294967295 : U32}

law distance_empty:
  {Main.response("", "") == "0" : String}

law distance_match:
  {Main.response("A", "A") == "0" : String}

law distance_substitution:
  {Main.response("A", "T") == "1" : String}

law distance_deletion:
  {Main.response("ACGT", "ACG") == "1" : String}

law distance_insertion:
  {Main.response("ACG", "ACGT") == "1" : String}

law distance_example:
  {Main.response("kitten", "sitting") == "3" : String}

# DP has its own entry point and boundary laws, independent of Myers.
law dp_empty_query:
  for target: String
  {DP.distance("", target) == String.length(target) : Nat}

law dp_empty_target:
  for query: String
  {DP.distance(query, "") == String.length(query) : Nat}

# The initial row holds D[0,j] = j, including the zero column.
law dp_row_width:
  for length: Nat
  for column: U32
  {List.length(&1, U32, DP.initial_row(length, column)) == 1n+length : Nat}

law dp_initial_row:
  {DP.initial_row(3n, 0) == [0, 1, 2, 3] : List<U32>}

# Record the unit-cost Levenshtein recurrence explicitly.
law dp_cell:
  for above: U32
  for left: U32
  for diagonal: U32
  for row_symbol: Char
  for column_symbol: Char
  {DP.cell(above, left, diagonal, row_symbol, column_symbol) ==
    U32.min(U32.min(U32.add(above, 1), U32.add(left, 1)),
      U32.add(diagonal, Bool.to_u32(Bool.not(Char.is_eq(row_symbol, column_symbol))))) : U32}

law dp_next_row:
  {DP.next_row([0, 1, 2], "AC", 'A', 1) == [1, 0, 1] : List<U32>}

law dp_match:
  {DP.distance("ACGT", "ACGT") == 0n : Nat}

law dp_substitution:
  {DP.distance("A", "T") == 1n : Nat}

law dp_deletion:
  {DP.distance("ACGT", "ACG") == 1n : Nat}

law dp_insertion:
  {DP.distance("ACG", "ACGT") == 1n : Nat}

law dp_example:
  {DP.distance("kitten", "sitting") == 3n : Nat}

# The bounded CLI validator is shared by both native Bend executables.
law cli_empty:
  for remaining: Nat
  {CLI.scan("", remaining) == CLI.Supported{} : CLI.InputStatus}

law cli_no_capacity:
  for h: Char
  for tail: String
  {CLI.scan(SCon{h, tail}, 0n) == CLI.TooLong{} : CLI.InputStatus}

law cli_ascii_edges:
  {CLI.scan(SCon{Chr{1}, SCon{Chr{127}, ""}}, 2n) == CLI.Supported{} : CLI.InputStatus}

law cli_non_ascii:
  {CLI.validate(SCon{Chr{256}, ""}, SCon{Chr{256}, ""}) == CLI.NonAscii{} : CLI.InputStatus}

law cli_empty_query_non_ascii:
  {CLI.validate("", SCon{Chr{256}, ""}) == CLI.NonAscii{} : CLI.InputStatus}

law cli_empty_target_non_ascii:
  {CLI.validate(SCon{Chr{256}, ""}, "") == CLI.NonAscii{} : CLI.InputStatus}

law cli_nul:
  {CLI.scan(SCon{Chr{0}, ""}, 1n) == CLI.NonAscii{} : CLI.InputStatus}

law cli_length_limit:
  {CLI.max_sequence_length() == 4096n : Nat}

# CLI contract (checked by Python integration tests):
# - Exactly two positional sequence arguments after the program name.
# - Successful stdout contains only the response and a trailing newline.
# - Invalid argument counts, non-ASCII characters and overlong inputs exit 2,
#   with a diagnostic on stderr and empty stdout, before distance evaluation.
# - Each sequence has at most 4096 characters (empty is allowed), U+0001..007F.
#   This bounds preprocessing, U32 scores and quadratic DP work. Each scan
#   examines at most 4097 characters; the two scans run in parallel.
# - Supported sequences use NW/global mode, unit edit costs,
#   unlimited distance (k = -1), one nonnegative decimal integer on stdout.
# - CLI arguments cannot contain NUL; use a future binary worker for that.
