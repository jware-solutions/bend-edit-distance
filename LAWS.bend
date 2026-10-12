import Base
import ./main.bend as Main
import ./DistanceDP.bend as DP
import ./Cli.bend as CLI
import ./EdlibTypes.bend as E
import ./Alignment.bend as A
import ./lib.bend as L
import ./ByteProtocol.bend as BT
import ./AlignmentCli.bend as AC
import ./Reconstruction.bend as R

# Byte transport maps each input byte to one Char with the same numeric value;
# it never decodes UTF-8, stops at NUL, or applies the ASCII CLI size limit.
# Frames and requests remain ordered, and EOF is accepted only between frames.
# Native framing/IO is outside the proof kernel; exercise it in test_transport.py.
law transport_byte_values:
  {BT.byte_string([0, 128, 255]) ==
    SCon{Chr{0}, SCon{Chr{128}, SCon{Chr{255}, ""}}} : String}

law transport_u32_order:
  {BT.u32_bytes(305419896) == [120, 86, 52, 18] : List<U32>}

# A missing optional field uses UINT32_MAX; a present empty field uses zero.
law transport_absent_starts:
  {BT.starts(None{}) == (4294967295, Nil{}) : U32 & List<U32>}

law transport_empty_starts:
  {BT.starts(Some{Nil{}}) == (0, Nil{}) : U32 & List<U32>}

# A finite first domain for alignment proofs: precisely every string of length
# 0..2 over {'A', 'a'}. This includes case differences and repeated symbols.
# It is a subset of the CLI's non-NUL ASCII domain, not all Bend Strings.
type SmallAscii is Data:
  EmptyAscii{}
  UpperAscii{}
  LowerAscii{}
  UpperUpperAscii{}
  UpperLowerAscii{}
  LowerUpperAscii{}
  LowerLowerAscii{}

def small_ascii(sequence: SmallAscii) -> String:
  match sequence:
    case EmptyAscii{}:
      ""
    case UpperAscii{}:
      "A"
    case LowerAscii{}:
      "a"
    case UpperUpperAscii{}:
      "AA"
    case UpperLowerAscii{}:
      "Aa"
    case LowerUpperAscii{}:
      "aA"
    case LowerLowerAscii{}:
      "aa"

# Exactly the three valid horizontal differences, with neither sign ambiguous.
type CarrySign is Data:
  NegativeCarry{}
  ZeroCarry{}
  PositiveCarry{}

def carry(sign: CarrySign) -> Main.Carry:
  match sign:
    case NegativeCarry{}:
      Main.Carry{0, 1}
    case ZeroCarry{}:
      Main.Carry{0, 0}
    case PositiveCarry{}:
      Main.Carry{1, 0}

def uniform_eq(matches: Bool) -> U32:
  match matches:
    case False{}:
      0
    case True{}:
      4294967295

def initial_carry(sign: CarrySign, matches: Bool) -> Main.Carry:
  match sign matches:
    case NegativeCarry{} _:
      Main.Carry{0, 1}
    case ZeroCarry{} False{}:
      Main.Carry{0, 0}
    case PositiveCarry{} False{}:
      Main.Carry{0, 0}
    case ZeroCarry{} True{}:
      Main.Carry{0, 1}
    case PositiveCarry{} True{}:
      Main.Carry{0, 1}

# Benchmark contract: same ordered corpus pairs, unrestricted NW/unit costs,
# supported ASCII, checksummed homogeneous batches, and pinned CPU affinity.
# Correctness on multiple threads is not a speedup proof. Timers and RSS use
# benchmark-only foreign effects; their measurements are runtime observations,
# outside these laws. Keep the 256-entry table/eight-step lookup unchanged until
# benchmarks/corpus.json and the phase/lookup probes have measured their costs.

# NW boundary conditions: deleting or inserting a whole sequence costs its
# length. These quantify over every string, rather than selected examples.
law empty_query:
  for target: String
  {Main.distance("", target) == String.length(target) : Nat}

law empty_target:
  for query: String
  {Main.distance(query, "") == String.length(query) : Nat}

# Query-profile padding must match every symbol, including a full empty word.
law wildcard_padding:
  for symbol: Char
  {Main.build_peq_word("", symbol, 1, Nil{}) == 4294967295 : U32}

# Structural invariants quantify over all Bend Strings (including Unicode)
# and unbounded Nat sizes. They make no alphabet or distance claim.
def rejoin(parts: String & String) -> String:
  (prefix, suffix) = parts
  String.append(prefix, suffix)

law split_rejoins:
  for size: Nat
  for query: String
  {rejoin(Main.split_query(size, query)) == query : String}

law split_prefix_length:
  for size: Nat
  for query: String
  {String.length(Pair.fst(String, String, Main.split_query(size, query))) ==
    Nat.min(size, String.length(query)) : Nat}

law initial_block_count:
  for count: Nat
  for bottom: U32
  {List.length(&1, Main.Block, Main.init_blocks(count, bottom)) == count : Nat}

# With no padding, decoding preserves every U32 score, even for unreachable
# bit-vector states. This does not assert nonwrapping arithmetic or optimality.
law decode_no_padding:
  for positive: U32
  for negative: U32
  for score: U32
  {Main.get_block_cell_value(0n, positive, negative, score) == score : U32}

# Outgoing carries depend only on the equality/vertical masks and incoming
# carry. Every U32 score is allowed, including wraparound values. This states
# independence of score storage, not validity of arbitrary input masks/carries.
law carry_score_independent:
  for positive: U32
  for negative: U32
  for eq: U32
  for incoming: Main.Carry
  for first_score: U32
  for second_score: U32
  {Pair.snd(Main.Block, Main.Carry,
    Main.calculate_block(Main.Block{positive, negative, first_score}, eq, incoming)) ==
    Pair.snd(Main.Block, Main.Carry,
      Main.calculate_block(Main.Block{positive, negative, second_score}, eq, incoming)) : Main.Carry}

# Carry propagation families: every U32 score, all three incoming signs, and
# a uniform equality word (all 32 positions match, or all mismatch). The first
# family has vertical differences +1 throughout; the second has -1 throughout.
# A negative incoming carry must propagate through an initial mismatching word.
# These do not assert correctness of arbitrary/reachable block states.
law initial_uniform_carry:
  for score: U32
  for incoming: CarrySign
  for matches: Bool
  {Pair.snd(Main.Block, Main.Carry,
    Main.calculate_block(Main.Block{4294967295, 0, score},
      uniform_eq(matches), carry(incoming))) == initial_carry(incoming, matches) : Main.Carry}

law finished_uniform_carry:
  for score: U32
  for incoming: CarrySign
  for matches: Bool
  {Pair.snd(Main.Block, Main.Carry,
    Main.calculate_block(Main.Block{0, 4294967295, score},
      uniform_eq(matches), carry(incoming))) == Main.Carry{1, 0} : Main.Carry}

law small_ascii_supported:
  for sequence: SmallAscii
  {CLI.scan(small_ascii(sequence), 2n) == CLI.Supported{} : CLI.InputStatus}

law small_ascii_identity:
  for sequence: SmallAscii
  {Main.distance(small_ascii(sequence), small_ascii(sequence)) == 0n : Nat}

law small_ascii_equivalence:
  for query: SmallAscii
  for target: SmallAscii
  {Main.distance(small_ascii(query), small_ascii(target)) ==
    DP.distance(small_ascii(query), small_ascii(target)) : Nat}

# Ordinary equality is case-sensitive; padding alone is a wildcard. Bit 31
# remains a real query position when the word is full (no wildcard high bits).
law mask_case_sensitive:
  {Main.build_peq_word("aA", 'A', 1, Nil{}) == 4294967294 : U32}

law mask_full_word_high_bit:
  {Main.build_peq_word("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC", 'C', 1, Nil{}) == 2147483648 : U32}

# The measured table lookup follows low bits first and preserves case/padding.
law table_lookup_ascii:
  {Main.peq_get(Main.build_peq_table(8n, "aA", 0, 1, Nil{}), 65, True{}) == 4294967294 : U32}

law table_lookup_missing:
  {Main.peq_get(Main.build_peq_table(8n, "aA", 0, 1, Nil{}), 128, False{}) == 4294967292 : U32}

# Reachable first-column states distinguish a negative carry from zero.
law block_match_carry:
  {Main.calculate_block(Main.Block{4294967295, 0, 32}, 4294967295, Main.Carry{1, 0}) ==
    (Main.Block{4294967294, 1, 31}, Main.Carry{0, 1}) : Main.Block & Main.Carry}

law block_mismatch_carry:
  {Main.calculate_block(Main.Block{4294967295, 0, 32}, 0, Main.Carry{1, 0}) ==
    (Main.Block{4294967294, 0, 32}, Main.Carry{0, 0}) : Main.Block & Main.Carry}

# After a full matching column sequence, a trailing mismatch inserts one more
# target character and produces a positive horizontal carry.
law block_positive_carry:
  {Main.calculate_block(Main.Block{0, 4294967295, 0}, 0, Main.Carry{1, 0}) ==
    (Main.Block{0, 4294967295, 1}, Main.Carry{1, 0}) : Main.Block & Main.Carry}

law block_decode_high_bit:
  {Main.get_block_cell_value(31n, 4294967294, 1, 31) == 0 : U32}

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

# For every String, previous row and U32 accumulator/symbol, a row step
# produces one cell per available column/predecessor. Only shape is claimed;
# arithmetic is still modulo 2^32 for unbounded callers.
law dp_row_cells_width:
  for columns: String
  for previous: List<U32>
  for diagonal: U32
  for left: U32
  for +symbol: Char
  for +pairs: List<&2, E.EqualityPair>
  {List.length(&1, U32, DP.row_cells(columns, previous, diagonal, left, symbol, pairs)) ==
    Nat.min(String.length(columns), List.length(&1, U32, previous)) : Nat}

law dp_initial_row:
  {DP.initial_row(3n, 0) == [0, 1, 2, 3] : List<U32>}

# Record the unit-cost Levenshtein recurrence explicitly.
law dp_cell:
  for above: U32
  for left: U32
  for diagonal: U32
  for row_symbol: Char
  for column_symbol: Char
  for pairs: List<&2, E.EqualityPair>
  {DP.cell(above, left, diagonal, row_symbol, column_symbol, pairs) ==
    U32.min(U32.min(U32.add(above, 1), U32.add(left, 1)),
      U32.add(diagonal, Bool.to_u32(Bool.not(E.equal(pairs, row_symbol, column_symbol))))) : U32}

law dp_next_row:
  {DP.next_row([0, 1, 2], "AC", 'A', 1, Nil{}) == [1, 0, 1] : List<U32>}

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
# - Identity, symmetry, length bounds and triangle inequality are tested only
#   for this unrestricted NW distance with ordinary character equality. These
#   tests are not proofs of the general metric laws, and do not apply to HW,
#   SHW, threshold sentinel results or arbitrary custom equality relations.
# - CLI arguments cannot contain NUL; use a future binary worker for that.

# Typed configuration/results: sentinel values never use unsigned wrapping.
# The legacy two-argument CLI and distance() helper retain the scalar NW API.
law typed_default_config:
  {E.default_config() == E.AlignConfig{E.NW{}, E.Distance{}, E.Unlimited{}, Nil{}, E.Extended{}} : E.AlignConfig}

law missing_distance_serialization:
  {E.distance_show(E.NotFound{}) == "-1" : String}

law found_distance_serialization:
  for value: Nat
  {E.distance_show(E.Found{value}) == Nat.show(value) : String}

law before_zero_serialization:
  {E.coordinate_show(E.BeforeStart{}) == "-1" : String}

law position_serialization:
  for index: Nat
  {E.coordinate_show(E.Position{index}) == Nat.show(index) : String}

law empty_end_coordinate:
  {E.end_coordinate(0n) == E.BeforeStart{} : E.Coordinate}

law nonempty_end_coordinate:
  for index: Nat
  {E.end_coordinate(1n+index) == E.Position{index} : E.Coordinate}

law unlimited_threshold:
  for value: Nat
  {E.within_threshold(E.Unlimited{}, value) == True{} : Bool}

law threshold_comparison:
  for maximum: Nat
  for value: Nat
  {E.within_threshold(E.MaxDistance{maximum}, value) == Nat.is_le(value, maximum) : Bool}

# Observable finite-k boundaries on nonempty ordinary NW inputs. The band
# uses 32-bit words; broader correctness is checked against independent DP
# and pinned Edlib, not claimed by these concrete or structural laws.
law threshold_zero_match:
  {Main.edlib_align("A", "A", E.AlignConfig{E.NW{}, E.Distance{}, E.MaxDistance{0n}, Nil{}, E.Extended{}}) ==
    E.distance_result(0n, E.Position{0n}, True{}) : E.AlignResult}

law threshold_inclusive:
  {Main.edlib_align("A", "T", E.AlignConfig{E.NW{}, E.Distance{}, E.MaxDistance{1n}, Nil{}, E.Extended{}}) ==
    E.distance_result(1n, E.Position{0n}, True{}) : E.AlignResult}

law threshold_exceeded:
  {Main.edlib_align("A", "T", E.AlignConfig{E.NW{}, E.Distance{}, E.MaxDistance{0n}, Nil{}, E.Extended{}}) ==
    E.not_found() : E.AlignResult}

law threshold_length_rejection:
  {Main.search_shorter("A", "AAAA", 1n, 4n, E.MaxDistance{2n}, True{}, Nil{}) ==
    Main.Search{E.NotFound{}, 0n, 0n, 0n} : Main.Search}

law negative_cli_threshold:
  # Parsing the entire i32 range is exercised natively; reducing a billion-
  # constructor Nat in the proof checker is unnecessary for normalization.
  {AC.negative_threshold(2n, True{}) == Some{E.Unlimited{}} : Maybe<&2, E.Threshold>}

law negative_wire_threshold:
  {BT.threshold(2147483648) == E.Unlimited{} : E.Threshold}

# The pinned upstream returns before processing k or task on empty inputs.
law empty_nw_threshold_task:
  for target: String
  for task: E.Task
  for threshold: E.Threshold
  {Main.edlib_align("", target, E.AlignConfig{E.NW{}, task, threshold, Nil{}, E.Extended{}}) ==
    E.distance_result(String.length(target), E.end_coordinate(String.length(target)), True{}) : E.AlignResult}

law empty_shw_threshold_task:
  for target: String
  for task: E.Task
  for threshold: E.Threshold
  {Main.edlib_align("", target, E.AlignConfig{E.SHW{}, task, threshold, Nil{}, E.Extended{}}) ==
    E.distance_result(0n, E.BeforeStart{}, True{}) : E.AlignResult}

law empty_hw_threshold_task:
  for target: String
  for task: E.Task
  for threshold: E.Threshold
  {Main.edlib_align("", target, E.AlignConfig{E.HW{}, task, threshold, Nil{}, E.Extended{}}) ==
    E.distance_result(0n, E.BeforeStart{}, True{}) : E.AlignResult}

# Directional boundaries: rows consume the original query; columns consume
# the original target. SHW penalizes a target prefix and frees its suffix.
# HW frees both target ends. Only NW may swap the two inputs.
law dp_shw_top_boundary:
  for length: Nat
  for column: U32
  {List.head(&1, U32, DP.initial_semiglobal_row(length, column, E.SHW{})) == Some{column} : Maybe<U32>}

law dp_hw_top_boundary:
  for length: Nat
  for column: U32
  {List.head(&1, U32, DP.initial_semiglobal_row(length, column, E.HW{})) == Some{0} : Maybe<U32>}

law shw_horizontal_boundary:
  {Main.semiglobal_carry(E.SHW{}) == Main.Carry{1, 0} : Main.Carry}

law hw_horizontal_boundary:
  {Main.semiglobal_carry(E.HW{}) == Main.Carry{0, 0} : Main.Carry}

law dp_shw_free_suffix:
  {DP.semiglobal("AC", "ACT", E.SHW{}, Nil{}) == DP.Best{0, [E.Position{1n}]} : DP.Best}

law dp_hw_free_prefix_suffix:
  {DP.semiglobal("AC", "TACG", E.HW{}, Nil{}) == DP.Best{0, [E.Position{2n}]} : DP.Best}

law shw_free_suffix:
  {Main.edlib_align("AC", "ACT", E.AlignConfig{E.SHW{}, E.Distance{}, E.MaxDistance{0n}, Nil{}, E.Extended{}}) ==
    E.distance_result(0n, E.Position{1n}, True{}) : E.AlignResult}

law shw_preserves_query:
  {Main.edlib_align("ACT", "AC", E.AlignConfig{E.SHW{}, E.Distance{}, E.Unlimited{}, Nil{}, E.Extended{}}) ==
    E.distance_result(1n, E.Position{1n}, True{}) : E.AlignResult}

law hw_preserves_query:
  {Main.edlib_align("ACT", "AC", E.AlignConfig{E.HW{}, E.Distance{}, E.Unlimited{}, Nil{}, E.Extended{}}) ==
    E.distance_result(1n, E.Position{1n}, True{}) : E.AlignResult}

law shw_prefix_threshold_exceeded:
  {Main.edlib_align("AC", "TAC", E.AlignConfig{E.SHW{}, E.Distance{}, E.MaxDistance{0n}, Nil{}, E.Extended{}}) ==
    E.not_found() : E.AlignResult}

law shw_prefix_threshold_inclusive:
  {Main.edlib_align("AC", "TAC", E.AlignConfig{E.SHW{}, E.Distance{}, E.MaxDistance{1n}, Nil{}, E.Extended{}}) ==
    E.distance_result(1n, E.Position{2n}, True{}) : E.AlignResult}

law hw_late_repeated_matches:
  {Main.edlib_align("AC", "TTACGGAC", E.AlignConfig{E.HW{}, E.Distance{}, E.MaxDistance{0n}, Nil{}, E.Extended{}}) ==
    E.AlignResult{E.Ok{}, E.Found{0n}, [E.Position{3n}, E.Position{7n}], None{}, None{}, None{}} : E.AlignResult}

law empty_target_threshold_mode:
  for query: String
  for mode: E.Mode
  for task: E.Task
  for threshold: E.Threshold
  {Main.edlib_align(query, "", E.AlignConfig{mode, task, threshold, Nil{}, E.Extended{}}) ==
    E.distance_result(String.length(query), E.BeforeStart{}, True{}) : E.AlignResult}

law threshold_not_found:
  for value: Nat
  for end: E.Coordinate
  {E.distance_result(value, end, False{}) ==
    E.AlignResult{E.Ok{}, E.NotFound{}, Nil{}, None{}, None{}, None{}} : E.AlignResult}

# Even DISTANCE includes the end location, without starts/path/CIGAR.
law distance_end_location:
  for value: Nat
  for end: E.Coordinate
  {E.distance_result(value, end, True{}) ==
    E.AlignResult{E.Ok{}, E.Found{value}, [end], None{}, None{}, None{}} : E.AlignResult}

# Every task uses the same accepted optimum and ordered ends. Additional
# fields are calculated only after k succeeds, and DISTANCE never asks for
# starts or traceback. HW resolves one start for each end using reverse SHW.
law task_failure_fields:
  for query: String
  for target: String
  for mode: E.Mode
  for task: E.Task
  for pairs: List<&2, E.EqualityPair>
  for format: E.CigarFormat
  for best: A.Best
  {Main.configured_result(query, target, mode, task, pairs, format, best, False{}) ==
    E.not_found() : E.AlignResult}

law distance_task_fields:
  for query: String
  for target: String
  for mode: E.Mode
  for pairs: List<&2, E.EqualityPair>
  for format: E.CigarFormat
  for score: U32
  for locations: List<&2, A.Location>
  {Main.configured_result(query, target, mode, E.Distance{}, pairs, format,
    A.Best{score, locations}, True{}) ==
    E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, A.ends(locations), None{}, None{}, None{}} : E.AlignResult}

law hw_before_start_location:
  for reverse_target: String
  for target_length: Nat
  for profiles: List<&2, Main.Peq>
  for query_length: Nat
  for maximum: Nat
  {Main.hw_location(A.Location{E.BeforeStart{}, 0n}, reverse_target, target_length,
    profiles, query_length, maximum) == A.Location{E.BeforeStart{}, 0n} : A.Location}

law hw_last_reverse_tie:
  {Main.hw_start_best(3n, A.Best{1,
    [A.Location{E.Position{1n}, 0n}, A.Location{E.Position{2n}, 0n}]}) ==
    A.Location{E.Position{3n}, 1n} : A.Location}

law nw_locations_keep_target_axis:
  {Main.edlib_align("TACGT", "AC", E.AlignConfig{E.NW{}, E.Locations{}, E.Unlimited{}, Nil{}, E.Extended{}}) ==
    E.AlignResult{E.Ok{}, E.Found{3n}, [E.Position{1n}], Some{[E.Position{0n}]}, None{}, None{}} : E.AlignResult}

law hw_earliest_start_tie:
  {Main.edlib_align("ABC", "XXBC", E.AlignConfig{E.HW{}, E.Locations{}, E.MaxDistance{1n}, Nil{}, E.Extended{}}) ==
    E.AlignResult{E.Ok{}, E.Found{1n}, [E.Position{3n}], Some{[E.Position{1n}]}, None{}, None{}} : E.AlignResult}

law hw_path_before_start:
  {Main.edlib_align("A", "TT", E.AlignConfig{E.HW{}, E.Path{}, E.MaxDistance{1n}, Nil{}, E.Extended{}}) ==
    E.AlignResult{E.Ok{}, E.Found{1n}, [E.BeforeStart{}, E.Position{0n}, E.Position{1n}],
      Some{[E.Position{0n}, E.Position{0n}, E.Position{1n}]}, Some{[E.Insert{}]}, Some{"1I"}} : E.AlignResult}

law equality_pair_reverse:
  {E.equal([E.EqualityPair{'A', 'N'}], 'N', 'A') == True{} : Bool}

law equality_pair_nontransitive:
  {E.equal([E.EqualityPair{'a', 'A'}, E.EqualityPair{'A', 'N'}], 'a', 'N') == False{} : Bool}

law equality_without_pairs:
  for a: Char
  for b: Char
  {E.equal(Nil{}, a, b) == Char.is_eq(a, b) : Bool}

law equality_literal_with_pairs:
  {E.equal([E.EqualityPair{'N', 'A'}], 'C', 'C') == True{} : Bool}

law equality_duplicate_reverse_pairs:
  {E.equal([E.EqualityPair{'A', 'a'}, E.EqualityPair{'A', 'a'},
    E.EqualityPair{'a', 'A'}], 'a', 'A') == True{} : Bool}

law equality_wildcard_nontransitive:
  {E.equal([E.EqualityPair{'N', 'A'}, E.EqualityPair{'N', 'C'}], 'A', 'C') == False{} : Bool}

law equality_zero_high_byte:
  {E.equal([E.EqualityPair{Chr{0}, Chr{255}}], Chr{255}, Chr{0}) == True{} : Bool}

law configured_wildcard_padding:
  for symbol: Char
  for pairs: List<&2, E.EqualityPair>
  {Main.build_peq_word("", symbol, 1, pairs) == 4294967295 : U32}

law configured_mask_case_insensitive:
  {Main.build_peq_word("aA", 'A', 1, [E.EqualityPair{'a', 'A'}]) == 4294967295 : U32}

law configured_mask_nontransitive:
  {Main.build_peq_word("ACN", 'C', 1,
    [E.EqualityPair{'N', 'A'}, E.EqualityPair{'N', 'C'}]) == 4294967294 : U32}

law configured_table_zero_high_byte:
  {Main.peq_get(Main.build_peq_table(8n, SCon{Chr{0}, ""}, 0, 1,
    [E.EqualityPair{Chr{0}, Chr{255}}]), 255, True{}) == 4294967295 : U32}

law configured_dp_case_insensitive:
  {DP.distance_with_equalities("aA", "AA", [E.EqualityPair{'a', 'A'}]) == 0n : Nat}

law configured_dp_nontransitive:
  {DP.distance_with_equalities("A", "C",
    [E.EqualityPair{'N', 'A'}, E.EqualityPair{'N', 'C'}]) == 1n : Nat}

law standard_cigar_merges_match_mismatch:
  {E.alignment_to_cigar([E.Match{}, E.Mismatch{}, E.Insert{}, E.Delete{}], E.Standard{}) == "2M1I1D" : String}

law extended_cigar_operations:
  {E.alignment_to_cigar([E.Match{}, E.Mismatch{}, E.Insert{}, E.Delete{}], E.Extended{}) == "1=1X1I1D" : String}

# CIGAR maps symbols before coalescing, emits positive decimal counts, and
# preserves an explicitly empty path as an empty string in either format.
# These rules cover encoding; they impose no optimal-path tie policy.
law cigar_empty:
  for format: E.CigarFormat
  {E.alignment_to_cigar(Nil{}, format) == "" : String}

law cigar_standard_runs:
  {E.alignment_runs([E.Match{}, E.Mismatch{}, E.Match{}, E.Insert{}, E.Insert{},
    E.Delete{}, E.Delete{}, E.Mismatch{}], E.Standard{}) ==
    [E.CigarRun{3n, 'M'}, E.CigarRun{2n, 'I'}, E.CigarRun{2n, 'D'}, E.CigarRun{1n, 'M'}] : List<&2, E.CigarRun>}

law cigar_extended_runs:
  {E.alignment_runs([E.Match{}, E.Match{}, E.Mismatch{}, E.Mismatch{},
    E.Insert{}, E.Insert{}, E.Delete{}, E.Delete{}], E.Extended{}) ==
    [E.CigarRun{2n, '='}, E.CigarRun{2n, 'X'}, E.CigarRun{2n, 'I'}, E.CigarRun{2n, 'D'}] : List<&2, E.CigarRun>}

law cigar_decimal_counts:
  {E.cigar_runs_show([E.CigarRun{10n, '='}, E.CigarRun{123n, 'I'}]) == "10=123I" : String}

law cigar_equality_matches:
  {E.alignment_to_cigar(R.dp("aN", "AA", [E.EqualityPair{'a', 'A'},
    E.EqualityPair{'N', 'A'}]), E.Extended{}) == "2=" : String}

law cigar_nontransitive_mismatch:
  {E.alignment_to_cigar(R.dp("A", "C", [E.EqualityPair{'N', 'A'},
    E.EqualityPair{'N', 'C'}]), E.Extended{}) == "1X" : String}

law library_alignment_to_cigar:
  for operations: List<&2, E.Operation>
  for format: E.CigarFormat
  {L.alignment_to_cigar(operations, format) == E.alignment_to_cigar(operations, format) : String}

# Reconstruction laws specify operation direction and validation explicitly.
# These finite examples and boundary rules do not prove general optimality or
# exact upstream tie selection. Hirschberg chooses the first minimum split.
law path_operation_codes:
  {[BT.operation_value(E.Match{}), BT.operation_value(E.Insert{}),
    BT.operation_value(E.Delete{}), BT.operation_value(E.Mismatch{})] == [0, 1, 2, 3] : List<U32>}

law path_transpose_operations:
  {R.transpose([E.Match{}, E.Insert{}, E.Delete{}, E.Mismatch{}]) ==
    [E.Match{}, E.Delete{}, E.Insert{}, E.Mismatch{}] : List<&2, E.Operation>}

law path_dp_cutoff:
  {(R.small_matrix(63n, 63n), R.small_matrix(64n, 64n)) ==
    (True{}, False{}) : Bool & Bool}

law path_dp_empty_query:
  {R.dp("", "AC", Nil{}) == [E.Delete{}, E.Delete{}] : List<&2, E.Operation>}

law path_dp_empty_target:
  {R.dp("AC", "", Nil{}) == [E.Insert{}, E.Insert{}] : List<&2, E.Operation>}

law path_dp_insert_direction:
  {R.dp("AC", "A", Nil{}) == [E.Match{}, E.Insert{}] : List<&2, E.Operation>}

law path_dp_delete_direction:
  {R.dp("A", "AC", Nil{}) == [E.Match{}, E.Delete{}] : List<&2, E.Operation>}

law path_dp_diagonals:
  {R.dp("AC", "AG", Nil{}) == [E.Match{}, E.Mismatch{}] : List<&2, E.Operation>}

law path_dp_traceback_tie:
  {R.dp("AC", "CA", Nil{}) == [E.Delete{}, E.Match{}, E.Insert{}] : List<&2, E.Operation>}

law path_divide_valid_tie:
  {R.valid_path("AC", "CA", R.divide(2n, "AC", "CA", 2n, 2n, Nil{}, False{}), Nil{}, 2n) ==
    True{} : Bool}

law path_validate_empty:
  {R.valid_path("", "", Nil{}, Nil{}, 0n) == True{} : Bool}

law path_validate_equalities:
  {R.valid_path("aN", "AA", [E.Match{}, E.Match{}],
    [E.EqualityPair{'a', 'A'}, E.EqualityPair{'N', 'A'}], 0n) == True{} : Bool}

law path_validate_nontransitive:
  {R.valid_path("a", "N", [E.Match{}],
    [E.EqualityPair{'a', 'A'}, E.EqualityPair{'A', 'N'}], 0n) == False{} : Bool}

law path_validate_wrong_cost:
  {R.valid_path("AC", "AG", [E.Match{}, E.Mismatch{}], Nil{}, 0n) == False{} : Bool}

law path_validate_partial_consumption:
  {R.valid_path("AC", "AC", [E.Match{}], Nil{}, 0n) == False{} : Bool}

law path_validate_overconsumption:
  {R.valid_path("A", "A", [E.Match{}, E.Insert{}], Nil{}, 1n) == False{} : Bool}

law path_validate_wrong_diagonal:
  {R.valid_path("A", "A", [E.Mismatch{}], Nil{}, 1n) == False{} : Bool}

law path_validate_wrong_gap_direction:
  {R.valid_path("A", "", [E.Delete{}], Nil{}, 1n) == False{} : Bool}

law path_invalid_interval:
  {A.location_valid("AC", A.Location{E.Position{1n}, 3n}) == False{} : Bool}

law path_invalid_before_start:
  {A.location_valid("AC", A.Location{E.BeforeStart{}, 1n}) == False{} : Bool}

law path_rejected_validation:
  for score: U32
  for locations: List<&2, A.Location>
  for format: E.CigarFormat
  for operations: List<&2, E.Operation>
  {A.path_checked(score, locations, format, operations, False{}) ==
    E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}} : E.AlignResult}

# The public package module preserves the distance and configured APIs.
law library_distance_matches_main:
  for query: String
  for target: String
  {L.distance(query, target) == Main.distance(query, target) : Nat}

law library_default_config:
  {L.default_config() == E.default_config() : E.AlignConfig}

law library_align_matches_main:
  for query: String
  for target: String
  for config: E.AlignConfig
  {L.align(query, target, config) == Main.edlib_align(query, target, config) : E.AlignResult}

# Configured DP cells and columns retain their dependencies. Independent
# input scans, Myers profile branches and Hirschberg score passes run in
# balanced parallel calls. DP matrices are bounded; larger PATHs use linear
# score storage, with insertion/deletion remapped after input transposition.
# Equalities are symmetric and nontransitive. Threshold failure has OK status,
# no locations and absent starts/path/CIGAR. PATH covers the first location.
# Pinned Edlib skips threshold filtering and starts/path on empty inputs.
# Generic configured DP is not a threshold-band optimization; it filters the
# final optimum. These laws do not prove general alignment optimality.
