import ./Prepared.bend as Q
import ./src/PreparedBytes.bend as PB
import ./src/ByteTarget.bend as Packed
import ./src/BitVector.bend as V
import ./src/Workspace.bend as W
import ./src/Word.bend as Word
import ./tests/dense_kernel.bend as Dense
import Base
import ./LAWS.bend as Laws
import ./src/DistanceDP.bend as DP
import ./src/Myers.bend as Myers
import ./EdlibTypes.bend as E
import ./src/Sequence.bend as S

def Laws.single_word_column(profile, block, mask):
  match block:
    case V.Block{pv, mv, score}:
      {==}

def Laws.single_word_shapes():
  {==}

def Laws.single_word_unknown_padding():
  {==}

def Laws.single_word_nontransitive():
  {==}

def Laws.single_word_high_bytes():
  {==}

def Laws.single_word_legacy_lookup():
  {==}

def Laws.two_word_carry(profile, first, second, carry, mask):
  match first second carry:
    case V.Block{_, _, _} V.Block{_, _, _} V.Carry{_, _}:
      {==}

def Laws.two_word_shapes():
  {==}

def Laws.two_word_unknown_padding():
  {==}

def Laws.two_word_boundary_match():
  {==}

def Laws.two_word_nontransitive():
  {==}

def Laws.retry_hint_empty(profile, index, limit):
  {==}

def Laws.retry_hint_logical_end(profile, symbol, tail, index, limit):
  {==}

def Laws.retry_hint_exceeded(fuel, target, index, limit, profile, distance):
  match fuel target:
    case 0n SNil{}:
      {==}
    case 0n SCon{_, _}:
      {==}
    case 1n+p SNil{}:
      {==}
    case 1n+p SCon{_, _}:
      {==}

def Laws.retry_hint_limit_conversion(length):
  {==}

def Laws.retry_hint_progress_conversion(length, consumed):
  {==}

def Laws.retry_hint_large_index():
  {==}

def Laws.retry_hint_limits():
  {==}

def Laws.retry_hint_progress():
  {==}

def Laws.retry_hint_unknown_padding():
  {==}

def Laws.retry_hint_nontransitive():
  {==}

def Laws.retry_hint_direct_equality():
  {==}

def Laws.block_transition_score_independence(positive, negative, score_a, score_b, mask, carry):
  match carry:
    case V.Carry{_, _}:
      {==}

def Laws.block_previous_boundary(positive, negative, score):
  {==}

def Laws.block_previous_initial():
  {==}

def Laws.three_restored_initial_scores(profile):
  {==}

def Laws.four_restored_initial_scores(profile):
  {==}

def Laws.three_word_mask_0(lookup, masks, rows, used, row):
  {==}

def Laws.three_word_mask_1(lookup, masks, rows, used, row):
  {==}

def Laws.three_word_mask_2(lookup, masks, rows, used, row):
  {==}

def Laws.four_word_mask_0(lookup, masks, rows, used, row):
  {==}

def Laws.four_word_mask_1(lookup, masks, rows, used, row):
  {==}

def Laws.four_word_mask_2(lookup, masks, rows, used, row):
  {==}

def Laws.four_word_mask_3(lookup, masks, rows, used, row):
  {==}

def Laws.packed_band_shapes():
  {==}

def Laws.packed_band_serial_cutoff():
  {==}

def Laws.byte_band_rejection_preserves_owners(bytes, profile, workspace, length, columns, maximum):
  {==}

def Laws.byte_band_empty_band(fuel, bytes, profile, workspace, index, length, columns, padding, column, blocks, work):
  match fuel workspace:
    case 0n W.Workspace{_, _, _, _}:
      {==}
    case 1n+p W.Workspace{_, _, _, _}:
      {==}

def Laws.byte_hint_empty(bytes, profile, index, limit):
  {==}

def Laws.byte_hint_exceeded(fuel, bytes, profile, index, limit, distance):
  match fuel:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.byte_band_counter_accumulation(bytes, profile, workspace, before, after):
  {==}

def Laws.packed_witness_eligibility():
  {==}

def Laws.packed_witness_zero_owner(query, pairs, length, columns, profile, workspace, bytes):
  {==}

def Laws.packed_witness_one_owner(query, pairs, length, columns, profile, workspace, bytes):
  {==}

def Laws.packed_witness_many_fallback(query, pairs, length, columns, profile, workspace, bytes, extra):
  {==}

def Laws.packed_witness_empty(bytes, profile):
  {==}

def Laws.packed_witness_prefix_exceeded(fuel, index, bytes, profile, distance):
  match fuel:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.packed_witness_reverse_exceeded(fuel, index, bytes, profile, distance):
  match fuel:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.packed_witness_direct_dp():
  {==}

def Laws.packed_witness_nontransitive_dp():
  {==}

def Laws.packed_witness_nul_high_dp():
  {==}

def Laws.packed_wide_shapes():
  {==}

def Laws.packed_three_word_steps(profile, first, second, third, word):
  {==}

def Laws.packed_four_word_steps(profile, first, second, third, fourth, word):
  {==}

def Laws.three_word_unknown_padding():
  {==}

def Laws.three_word_boundary_match():
  {==}

def Laws.four_word_unknown_padding():
  {==}

def Laws.four_word_boundary_match():
  {==}

def Laws.packed_byte_order():
  {==}

def Laws.packed_capacity_guards():
  {==}

def Laws.packed_string_bytes():
  {==}

def Laws.packed_string_partial():
  {==}

def Laws.packed_invalid_length():
  {==}

def Laws.packed_generic_query():
  {==}

def Laws.packed_generic_pairs():
  {==}

def Laws.packed_nontransitive():
  {==}

def Laws.packed_pool_serial_small():
  {==}

def Laws.packed_pool_parallel_large():
  {==}

def Laws.packed_pool_four_word_serial():
  {==}

def Laws.packed_pool_four_word_parallel():
  {==}

def Laws.packed_pool_three_word_conservative():
  {==}

def Laws.packed_pool_empty_work():
  {==}

def Laws.packed_one_word_steps(profile, block, word):
  {==}

def Laws.packed_two_word_steps(profile, first, second, word):
  {==}

def Laws.packed_prepared_equivalence(query, target):
  match query target:
    case Laws.EmptyAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerLowerAscii{}:
      {==}

# The accumulator traversal preserves the existing String.length contracts.
def add_successor(+a: Nat, +b: Nat) ->
    {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.add(p, 1n+b), 1n+Nat.add(p, b), add_successor(p, b))

def add_zero_right(a: Nat) -> {Nat.add(a, 0n) == a : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.add(p, 0n), p, add_zero_right(p))

def length_from_correct(+sequence: String, +count: Nat) ->
    {S.length_from(sequence, count) == Nat.add(String.length(sequence), count) : Nat}:
  match sequence:
    case SNil{}:
      {==}
    case SCon{_, +tail}:
      Equal.trans(Nat, S.length_from(tail, 1n+count),
        Nat.add(String.length(tail), 1n+count), 1n+Nat.add(String.length(tail), count),
        length_from_correct(tail, 1n+count), add_successor(String.length(tail), count))

def sequence_length_correct(+sequence: String) ->
    {S.length(sequence) == String.length(sequence) : Nat}:
  Equal.trans(Nat, S.length(sequence), Nat.add(String.length(sequence), 0n),
    String.length(sequence), length_from_correct(sequence, 0n), add_zero_right(String.length(sequence)))

def Laws.gpu_execution_values(plan):
  {==}

def Laws.gpu_prepared_execution_values(plan, options, known_bytes):
  {==}

def Laws.pinned_capabilities():
  {==}

def Laws.word_geometry():
  {==}

def Laws.word_padding():
  {==}

def Laws.endpoint_convention_independent():
  {==}

def Laws.indexed_trace_geometry():
  {==}

def Laws.known_path_zero():
  {==}

def Laws.known_path_one():
  {==}

def Laws.known_path_gap_tie():
  {==}

def Laws.known_path_invalid_score():
  {==}

def Laws.hw_fixed_single_symbol():
  {==}

def Laws.hw_fixed_zero_distance():
  {==}

def Laws.workspace_storage_rounding():
  {==}

def Laws.workspace_selected_padding():
  {==}

def Laws.workspace_selected_logical_guard():
  {==}

def Laws.workspace_row_selection():
  {==}

def Laws.transport_coordinate_values():
  {==}

def Laws.transport_optional_coordinate_values():
  {==}

def Laws.transport_optional_operation_values():
  {==}

def Laws.tail_take_small_equivalence(sequence):
  match sequence:
    case Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{}:
      {==}

def Laws.tail_take_zero(sequence):
  match sequence:
    case SNil{}:
      {==}
    case SCon{_, _}:
      {==}

def Laws.tail_take_nonbyte():
  {==}

def Laws.path_list_append_suffix(suffix):
  match suffix:
    case Nil{}:
      {==}
    case _ <> _:
      {==}

def Laws.trace_suffix_preserves_tie(suffix):
  {==}

def Laws.trace_fill_preserves_tie():
  {==}

def Laws.library_pool_batch_values(pool, targets, options):
  {==}

def Laws.pool_generic_byte_boundary(ready, options):
  {==}

def Laws.pool_single_result_order(pool, result, tail):
  {==}

def Laws.pool_wave_reindex_preserves_metadata(old, sequence, length, work, tail, index):
  {==}

def Laws.pool_distance_endpoint(columns, distance):
  {==}

def Laws.pool_distance_rejection(columns):
  {==}

def Laws.pool_generic_execution(plan, options):
  {==}

def Laws.bounded_path_generic_fallback(query, target, pairs, distance):
  {==}

def Laws.small_path_trail_suffix(operation, matches, previous, suffix):
  {==}

def Laws.small_path_insert_bounds(index, target, trail):
  {==}

def Laws.small_path_delete_bounds(index, query, trail):
  {==}

def Laws.small_path_nontransitive_rejection():
  {==}

def Laws.small_path_nontransitive_match():
  {==}

def Laws.small_path_substitution():
  {==}

def Laws.small_path_one_gap():
  {==}

def Laws.small_path_empty_query():
  {==}

def Laws.small_path_finite_rejection():
  {==}

def Laws.indexed_trace_cell_tie():
  {==}

def Laws.indexed_trace_score_boundary():
  {==}

def Laws.indexed_trace_small_equivalence(query, target):
  match query target:
    case Laws.EmptyAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerLowerAscii{}:
      {==}


def Laws.indexed_trace_nonbyte():
  {==}

def Laws.gpu_batch_empty():
  {==}

def Laws.gpu_batch_singleton(query, target, config):
  {==}

def Laws.batch_empty():
  {==}

def Laws.batch_singleton(query, target, config):
  {==}

def Laws.batch_restores_indices():
  {==}

def Laws.path_operation_codes():
  {==}

def Laws.path_transpose_operations():
  {==}

def Laws.path_dp_cutoff():
  {==}

def Laws.path_dp_empty_query():
  {==}

def Laws.path_dp_empty_target():
  {==}

def Laws.path_dp_insert_direction():
  {==}

def Laws.path_dp_delete_direction():
  {==}

def Laws.path_dp_diagonals():
  {==}

def Laws.path_dp_traceback_tie():
  {==}

def Laws.path_divide_valid_tie():
  {==}

def Laws.path_validate_empty():
  {==}

def Laws.path_validate_equalities():
  {==}

def Laws.path_validate_nontransitive():
  {==}

def Laws.path_validate_wrong_cost():
  {==}

def Laws.path_validate_partial_consumption():
  {==}

def Laws.path_validate_overconsumption():
  {==}

def Laws.path_validate_wrong_diagonal():
  {==}

def Laws.path_validate_wrong_gap_direction():
  {==}

def Laws.path_invalid_interval():
  {==}

def Laws.path_invalid_before_start():
  {==}

def Laws.path_rejected_validation(score, locations, format, operations):
  {==}

def Laws.transport_byte_values():
  {==}

def Laws.transport_u32_order():
  {==}

def Laws.transport_absent_starts():
  {==}

def Laws.transport_empty_starts():
  {==}

def Laws.typed_default_config():
  {==}

def Laws.missing_distance_serialization():
  {==}

def Laws.found_distance_serialization(value):
  {==}

def Laws.before_zero_serialization():
  {==}

def Laws.position_serialization(index):
  {==}

def Laws.empty_end_coordinate():
  {==}

def Laws.nonempty_end_coordinate(index):
  {==}

def Laws.unlimited_threshold(value):
  {==}

def Laws.threshold_comparison(maximum, value):
  {==}

def Laws.threshold_zero_match():
  {==}

def Laws.threshold_inclusive():
  {==}

def Laws.threshold_exceeded():
  {==}

def Laws.threshold_length_rejection():
  {==}

def Laws.dp_shw_top_boundary(length, column):
  match length:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.dp_hw_top_boundary(length, column):
  match length:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.shw_horizontal_boundary():
  {==}

def Laws.hw_horizontal_boundary():
  {==}

def Laws.dp_shw_free_suffix():
  {==}

def Laws.dp_hw_free_prefix_suffix():
  {==}

def Laws.shw_free_suffix():
  {==}

def Laws.shw_preserves_query():
  {==}

def Laws.hw_preserves_query():
  {==}

def Laws.shw_prefix_threshold_exceeded():
  {==}

def Laws.shw_prefix_threshold_inclusive():
  {==}

def Laws.hw_late_repeated_matches():
  {==}

def Laws.empty_target_threshold_mode(query, mode, task, threshold):
  match query mode task:
    case SNil{} E.NW{} E.Distance{}:
      {==}
    case SNil{} E.NW{} E.Locations{}:
      {==}
    case SNil{} E.NW{} E.Path{}:
      {==}
    case SNil{} E.SHW{} E.Distance{}:
      {==}
    case SNil{} E.SHW{} E.Locations{}:
      {==}
    case SNil{} E.SHW{} E.Path{}:
      {==}
    case SNil{} E.HW{} E.Distance{}:
      {==}
    case SNil{} E.HW{} E.Locations{}:
      {==}
    case SNil{} E.HW{} E.Path{}:
      {==}
    case SCon{h, t} E.NW{} E.Distance{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.NW{} E.Locations{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.NW{} E.Path{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.SHW{} E.Distance{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.SHW{} E.Locations{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.SHW{} E.Path{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.HW{} E.Distance{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.HW{} E.Locations{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))
    case SCon{h, t} E.HW{} E.Path{}:
      Equal.cong(Nat, E.AlignResult, n => E.distance_result(1n+n, E.BeforeStart{}, True{}),
        S.length(t), String.length(t), sequence_length_correct(t))

def Laws.negative_cli_threshold():
  {==}

def Laws.negative_wire_threshold():
  {==}

def Laws.empty_nw_threshold_task(target, task, threshold):
  match target task:
    case SNil{} E.Distance{}:
      {==}
    case SNil{} E.Locations{}:
      {==}
    case SNil{} E.Path{}:
      {==}
    case SCon{h, t} E.Distance{}:
      Equal.cong(Nat, E.AlignResult, +n => E.distance_result(n, E.end_coordinate(n), True{}),
        S.length(SCon{h, t}), String.length(SCon{h, t}), sequence_length_correct(SCon{h, t}))
    case SCon{h, t} E.Locations{}:
      Equal.cong(Nat, E.AlignResult, +n => E.distance_result(n, E.end_coordinate(n), True{}),
        S.length(SCon{h, t}), String.length(SCon{h, t}), sequence_length_correct(SCon{h, t}))
    case SCon{h, t} E.Path{}:
      Equal.cong(Nat, E.AlignResult, +n => E.distance_result(n, E.end_coordinate(n), True{}),
        S.length(SCon{h, t}), String.length(SCon{h, t}), sequence_length_correct(SCon{h, t}))

def Laws.empty_shw_threshold_task(target, task, threshold):
  match target task:
    case SNil{} E.Distance{}:
      {==}
    case SNil{} E.Locations{}:
      {==}
    case SNil{} E.Path{}:
      {==}
    case SCon{h, t} E.Distance{}:
      {==}
    case SCon{h, t} E.Locations{}:
      {==}
    case SCon{h, t} E.Path{}:
      {==}

def Laws.empty_hw_threshold_task(target, task, threshold):
  match target task:
    case SNil{} E.Distance{}:
      {==}
    case SNil{} E.Locations{}:
      {==}
    case SNil{} E.Path{}:
      {==}
    case SCon{h, t} E.Distance{}:
      {==}
    case SCon{h, t} E.Locations{}:
      {==}
    case SCon{h, t} E.Path{}:
      {==}

def Laws.threshold_not_found(value, end):
  {==}

def Laws.distance_end_location(value, end):
  {==}

def Laws.task_failure_fields(query, target, mode, task, pairs, format, best):
  {==}

def Laws.distance_task_fields(query, target, mode, pairs, format, score, locations):
  match mode:
    case E.NW{}:
      {==}
    case E.SHW{}:
      {==}
    case E.HW{}:
      {==}

def Laws.hw_before_start_location(reverse_target, target_length, profiles, query_length, maximum):
  {==}

def Laws.hw_last_reverse_tie():
  {==}

def Laws.nw_locations_keep_target_axis():
  {==}

def Laws.hw_earliest_start_tie():
  {==}

def Laws.hw_path_before_start():
  {==}

def Laws.equality_pair_reverse():
  {==}

def Laws.equality_pair_nontransitive():
  {==}

def Laws.standard_cigar_merges_match_mismatch():
  {==}

def Laws.extended_cigar_operations():
  {==}

def Laws.cigar_empty(format):
  {==}

def Laws.cigar_standard_runs():
  {==}

def Laws.cigar_extended_runs():
  {==}

def Laws.cigar_decimal_counts():
  {==}

def Laws.cigar_equality_matches():
  {==}

def Laws.cigar_nontransitive_mismatch():
  {==}

def Laws.library_alignment_to_cigar(operations, format):
  {==}

def Laws.small_ascii_equivalence(query, target):
  match query target:
    case Laws.EmptyAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerLowerAscii{}:
      {==}

def split_rejoins_step(h: Char, parts: String & String) ->
  {SCon{h, Laws.rejoin(parts)} == Laws.rejoin(V.split_query.prepend(h, parts)) : String}:
  match parts:
    case (prefix, suffix):
      {==}

def Laws.split_rejoins(size, query):
  match size query:
    case 0n _:
      {==}
    case 1n+p SNil{}:
      {==}
    case Succ{+p} SCon{+h, +t}:
      %split_rejoins_step(h, V.split_query(p, t)) : {_ == SCon{h, t} : String}
      %Laws.split_rejoins(p, t) : {SCon{h, Laws.rejoin(V.split_query(p, t))} == SCon{h, _} : String}
      {==}

def split_prefix_step(h: Char, parts: String & String) ->
  {1n+String.length(Pair.fst(String, String, parts)) ==
    String.length(Pair.fst(String, String, V.split_query.prepend(h, parts))) : Nat}:
  match parts:
    case (prefix, suffix):
      {==}

def Laws.split_prefix_length(size, query):
  match size query:
    case 0n _:
      {==}
    case 1n+p SNil{}:
      {==}
    case Succ{+p} SCon{+h, +t}:
      %split_prefix_step(h, V.split_query(p, t)) : {_ == 1n+Nat.min(p, String.length(t)) : Nat}
      %Laws.split_prefix_length(p, t) :
        {1n+String.length(Pair.fst(String, String, V.split_query(p, t))) == 1n+_ : Nat}
      {==}

def Laws.initial_block_count(count, bottom):
  match count:
    case 0n:
      {==}
    case 1n+p:
      %Laws.initial_block_count(p, U32.add(bottom, 32)) :
        {1n+List.length(&1, V.Block, V.init_blocks(p, U32.add(bottom, 32))) == 1n+_ : Nat}
      {==}

def Laws.decode_no_padding(positive, negative, score):
  {==}

def Laws.carry_score_independent(positive, negative, eq, incoming, first_score, second_score):
  match incoming:
    case V.Carry{hin_positive, hin_negative}:
      {==}

def Laws.initial_uniform_carry(score, incoming, matches):
  match incoming matches:
    case Laws.NegativeCarry{} False{}:
      {==}
    case Laws.NegativeCarry{} True{}:
      {==}
    case Laws.ZeroCarry{} False{}:
      {==}
    case Laws.ZeroCarry{} True{}:
      {==}
    case Laws.PositiveCarry{} False{}:
      {==}
    case Laws.PositiveCarry{} True{}:
      {==}

def Laws.finished_uniform_carry(score, incoming, matches):
  match incoming matches:
    case Laws.NegativeCarry{} False{}:
      {==}
    case Laws.NegativeCarry{} True{}:
      {==}
    case Laws.ZeroCarry{} False{}:
      {==}
    case Laws.ZeroCarry{} True{}:
      {==}
    case Laws.PositiveCarry{} False{}:
      {==}
    case Laws.PositiveCarry{} True{}:
      {==}

def Laws.small_ascii_supported(sequence):
  match sequence:
    case Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{}:
      {==}

def Laws.small_ascii_identity(sequence):
  match sequence:
    case Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{}:
      {==}

def Laws.empty_query(target):
  sequence_length_correct(target)

def Laws.empty_target(query):
  match query:
    case SNil{}:
      {==}
    case SCon{h, t}:
      Equal.cong(Nat, Nat, n => 1n+n, S.length(t), String.length(t), sequence_length_correct(t))

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

def Laws.dp_row_cells_width(columns, previous, diagonal, left, symbol, pairs):
  match columns previous:
    case SNil{} _:
      {==}
    case SCon{h, t} Nil{}:
      {==}
    case SCon{+h, t} +above <> rest:
      %Laws.dp_row_cells_width(t, rest, above, DP.cell(above, left, diagonal, symbol, h, pairs), symbol, pairs) :
        {1n+List.length(&1, U32, DP.row_cells(t, rest, above,
          DP.cell(above, left, diagonal, symbol, h, pairs), symbol, pairs)) == 1n+_ : Nat}
      {==}

def Laws.dp_cell(above, left, diagonal, row_symbol, column_symbol, pairs):
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

def Laws.library_distance_matches_main(query, target):
  {==}

def Laws.library_default_config():
  {==}

def Laws.library_align_matches_main(query, target, config):
  {==}

def Laws.equality_without_pairs(a, b):
  {==}

def Laws.equality_literal_with_pairs():
  {==}

def Laws.equality_literal_any_pairs(pairs):
  match pairs:
    case Nil{}:
      {==}
    case pair <> tail:
      {==}

def Laws.equality_duplicate_reverse_pairs():
  {==}

def Laws.equality_wildcard_nontransitive():
  {==}

def Laws.equality_zero_high_byte():
  {==}

def Laws.configured_wildcard_padding(symbol, pairs):
  {==}

def Laws.configured_mask_case_insensitive():
  {==}

def Laws.configured_mask_nontransitive():
  {==}

def Laws.configured_table_zero_high_byte():
  {==}

def Laws.configured_dp_case_insensitive():
  {==}

def Laws.configured_dp_nontransitive():
  {==}

def Laws.compact_missing_mask(masks, index):
  {==}

def Laws.compact_padding_full_word(last):
  match last:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.compact_padding_nonfinal(used):
  {==}

def Laws.compact_padding_one():
  {==}

def Laws.workspace_capacity(count):
  {==}

def Laws.workspace_initial_blocks():
  {==}

def Laws.workspace_retry_reset():
  {==}

def Laws.nw_initial_band_longer():
  {==}

def Laws.nw_orientation_square():
  {==}

def Laws.nw_orientation_conservative():
  {==}

def Laws.prepared_empty_target(prepared, options):
  match prepared options:
    case Q.Prepared{SNil{}, pairs, length, None{}, workspace} Q.Options{mode, task, threshold, format}:
      {==}
    case Q.Prepared{SNil{}, pairs, length, Some{profile}, workspace} Q.Options{mode, task, threshold, format}:
      {==}
    case Q.Prepared{SCon{h, t}, pairs, length, None{}, workspace} Q.Options{mode, task, threshold, format}:
      {==}
    case Q.Prepared{SCon{h, t}, pairs, length, Some{profile}, workspace} Q.Options{mode, task, threshold, format}:
      {==}

def Laws.prepared_nw_equivalence():
  {==}

def Laws.prepared_nontransitive_equivalence():
  {==}

def Laws.batch_gather_guard(array, index, value):
  {==}

def Laws.batch_gather_duplicate():
  {==}

def Laws.batch_gather_permutation():
  {==}


def Laws.frontier_empty_query(target, pairs):
  {==}

def Laws.frontier_empty_prefix():
  {==}

def Laws.frontier_nontransitive():
  {==}

def Laws.frontier_word_boundary():
  {==}

def Laws.frontier_generic_fallback():
  {==}

def Laws.frontier_small_equivalence(query, target):
  match query target:
    case Laws.EmptyAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.EmptyAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.UpperLowerAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerUpperAscii{} Laws.LowerLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.EmptyAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.UpperLowerAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerUpperAscii{}:
      {==}
    case Laws.LowerLowerAscii{} Laws.LowerLowerAscii{}:
      {==}

def Laws.word_population_count():
  {==}

def Laws.word_population_alternating():
  {==}

def Laws.fast_decode_no_padding(positive, negative, score):
  {==}

def Laws.fast_decode_wraps():
  {==}

def Laws.nw_empty_band_owners(target, profile, workspace, length, columns, padding, column, blocks, maximum, work):
  match target workspace:
    case SNil{} W.Workspace{_, _, _, _}:
      {==}
    case SCon{_, _} W.Workspace{_, _, _, _}:
      {==}

def Laws.nw_incomplete_owners(profile, workspace, maximum, padding, blocks, columns):
  {==}

def Laws.nw_skip_expansion(profile, workspace, score, carry, symbol, maximum, length, columns, column, work):
  match workspace carry:
    case W.Workspace{_, _, _, _} V.Carry{_, _}:
      {==}

def Laws.nw_activation_reset(profile, workspace, index, previous, carry, row, maximum, length, columns, column, work):
  {==}

def Laws.workspace_empty_reset(data, capacity, first, last):
  {==}

def Laws.dense_reset_owners(profile, data, capacity, first, last, length):
  {==}

def Laws.dense_column_recurrence(h, target, profile, workspace, padding, columns, work, old_score, old_carry):
  {==}

def Laws.dense_final_padding(profile, workspace, padding, columns, work, score, carry):
  {==}

def Laws.dense_packed_owner(bytes, profile, workspace, index, padding, columns, work, maximum, previous, empty):
  {==}

def Laws.dense_threshold_inclusive(profile, workspace, maximum, score, blocks, columns, attempts):
  {==}

def Laws.dense_rejection_owners(target, profile, workspace, length, columns, maximum):
  {==}

def Laws.dense_fallback(target, profile, workspace, length, columns, threshold):
  {==}

def Laws.dense_empty_exception(target, profile, workspace, columns, threshold):
  match columns threshold:
    case 0n E.Unlimited{}:
      {==}
    case 0n E.MaxDistance{_}:
      {==}
    case 1n+p E.Unlimited{}:
      {==}
    case 1n+p E.MaxDistance{_}:
      {==}

def Laws.dense_guard_components(a, b, room):
  match a b room:
    case False{} False{} False{}:
      {==}
    case False{} False{} True{}:
      {==}
    case False{} True{} False{}:
      {==}
    case False{} True{} True{}:
      {==}
    case True{} False{} False{}:
      {==}
    case True{} False{} True{}:
      {==}
    case True{} True{} False{}:
      {==}
    case True{} True{} True{}:
      {==}

def Laws.dense_arithmetic_guard(length, columns):
  Laws.dense_guard_components(Dense.work_room(length, columns), True{},
    Nat.is_le(Nat.add(Nat.mul(Word.blocks(length), Word.width()), columns), 4294967294n))

def Laws.dense_unsupported_lengths(length, columns):
  {==}

def Laws.dense_guard_left(a, b):
  match a b:
    case False{} False{}:
      {==}
    case False{} True{}:
      {==}
    case True{} False{}:
      {==}
    case True{} True{}:
      {==}

def Laws.dense_work_guard(length, columns):
  Laws.dense_guard_left(Dense.work_room(length, columns),
    Nat.is_le(Nat.add(Nat.mul(Word.blocks(length), Word.width()), columns), 4294967294n))

def Laws.certificate_add_successor(a, b):
  match a:
    case 0n:
      {==}
    case 1n+p:
      %Laws.certificate_add_successor(p, b) : {1n+Nat.add(p, 1n+b) == 1n+_ : Nat}
      {==}

def Laws.certificate_nonnegative(value):
  match value:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.certificate_gap_pair_lower_bound(extra_pairs, substitutions):
  %Equal.sym(Nat, Nat.add(extra_pairs, 1n+extra_pairs), 1n+Nat.add(extra_pairs, extra_pairs),
    Laws.certificate_add_successor(extra_pairs, extra_pairs)) :
    {Nat.is_lt(Nat.add(1n+_, substitutions), 2n) == False{} : Bool}
  Laws.certificate_nonnegative(Nat.add(Nat.add(extra_pairs, extra_pairs), substitutions))


def Laws.certificate_two_substitutions_bounds():
  {==}

def Laws.certificate_script_lower_bound(script):
  match script:
    case Laws.DiagonalTwo{}:
      {==}
    case Laws.GapPairs{extra, substitutions}:
      Laws.certificate_gap_pair_lower_bound(extra, substitutions)

def Laws.two_diagonal_direct_nontransitive_dp():
  {==}

def Laws.packed_witness_two_inconclusive():
  {==}

def Laws.packed_witness_rotation_inconclusive():
  {==}

def Laws.diagonal_three_is_only_upper_bound():
  {==}

def Laws.two_diagonal_third_mismatch(profile):
  {==}

def Laws.packed_witness_invalid_owner(state, target):
  match state target:
    case PB.Known{_, _, _, _, _} Packed.Target{_, 0n}:
      {==}
    case PB.Known{_, _, _, _, _} Packed.Target{_, 1n+p}:
      {==}

def preparation_or_commutes(+a: Bool, +b: Bool) -> {Bool.or(a, b) == Bool.or(b, a) : Bool}:
  match a b:
    case True{} True{}:
      {==}
    case True{} False{}:
      {==}
    case False{} True{}:
      {==}
    case False{} False{}:
      {==}

def Laws.preparation_pair_reversal(first, second, a, b):
  preparation_or_commutes(Bool.and(Char.is_eq(a, first), Char.is_eq(b, second)),
    Bool.and(Char.is_eq(a, second), Char.is_eq(b, first)))

def preparation_or_duplicate(+a: Bool, +b: Bool) -> {Bool.or(a, Bool.or(a, b)) == Bool.or(a, b) : Bool}:
  match a:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.preparation_duplicate_edge(pair, pairs, a, b):
  preparation_or_duplicate(E.pair_matches(pair, a, b), E.equal.scan(pairs, a, b))

def Laws.preparation_duplicate_relevance(query, symbol, pair, pairs):
  match query:
    case SNil{}:
      {==}
    case SCon{+h, +t}:
      %Laws.preparation_duplicate_edge(pair, pairs, h, symbol) :
        {Bool.or(E.equal.scan(pair <> pair <> pairs, h, symbol), Laws.preparation_relevant(t, symbol, pair <> pair <> pairs)) ==
         Bool.or(_, Laws.preparation_relevant(t, symbol, pair <> pairs)) : Bool}
      %Laws.preparation_duplicate_relevance(t, symbol, pair, pairs) :
        {Bool.or(E.equal.scan(pair <> pair <> pairs, h, symbol), Laws.preparation_relevant(t, symbol, pair <> pair <> pairs)) ==
         Bool.or(E.equal.scan(pair <> pair <> pairs, h, symbol), _) : Bool}
      {==}


def Laws.preparation_original_literals():
  {==}

def Laws.preparation_nontransitive_masks():
  {==}

def Laws.preparation_real_mask_equivalence():
  {==}

def Laws.preparation_removed_padding_row():
  {==}

def Laws.preparation_logical_row_guard():
  {==}

def Laws.preparation_logical_block_guard():
  {==}

def Laws.preparation_accounted_capacity():
  {==}

def Laws.preparation_bitmap_bounds():
  {==}

def Laws.preparation_duplicate_and_reflexive_masks():
  {==}

def preparation_sub_zero(value: Nat) -> {Nat.sub(value, 0n) == value : Nat}:
  match value:
    case 0n:
      {==}
    case 1n+p:
      {==}

def Laws.preparation_private_charge_recovery(shared, buffers):
  match shared:
    case 0n:
      preparation_sub_zero(buffers)
    case 1n+p:
      Laws.preparation_private_charge_recovery(p, buffers)

def Laws.preparation_shared_charge_recovery(shared, buffers):
  match buffers:
    case 0n:
      %add_zero_right(shared) : {Nat.sub(Nat.add(shared, 0n), 0n) == _ : Nat}
      preparation_sub_zero(Nat.add(shared, 0n))
    case 1n+p:
      Equal.trans(Nat,
        Nat.sub(Nat.add(shared, 1n+p), 1n+p),
        Nat.sub(1n+Nat.add(shared, p), 1n+p), shared,
        Equal.cong(Nat, Nat, n => Nat.sub(n, 1n+p),
          Nat.add(shared, 1n+p), 1n+Nat.add(shared, p), add_successor(shared, p)),
        Laws.preparation_shared_charge_recovery(shared, p))
