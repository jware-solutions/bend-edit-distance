import Base
import ./Sequence.bend as S
import ../EdlibTypes.bend as E
import ./Alignment.bend as A

# The distance paths from vendor/edlib/edlib/src/edlib.cpp. Bend's native
# integer is U32, so a Myers word covers 32 query characters instead of 64.
# The scalar helper is NW, unit costs, unlimited distance (k = -1). The
# configured API extends it with the typed modes/tasks in EdlibTypes.bend.

import ./BitVector.bend as V

# An active entry owns its current block and shares its immutable profile.
# Dropped leading entries are never visited again. Trailing profiles remain
# available for expansion; retries share the full profile but reset all blocks.
type BandEntry is Data:
  BandEntry{profile: V.Peq, block: V.Block}

type Band is Type:
  Band{first: Nat, entries: List<&2, BandEntry>, rest: List<&2, V.Peq>}

type UpdatedBand is Type:
  UpdatedBand{entries: List<&2, BandEntry>, score: U32, carry: V.Carry, bottom: Nat}

type BandStep is Type:
  BandStep{band: Band, maximum: Nat, work: Nat}

# Work counts actual V.calculate_block calls, consumed columns and fresh attempts.
# The probe uses these production counters to verify pruning and retry behavior.
type Search is Data:
  Search{distance: E.EditDistance, blocks: Nat, columns: Nat, attempts: Nat}

def init_band_entries.step(parts: List<&2, BandEntry> & List<&2, V.Peq>,
                           profile: V.Peq, bottom: U32) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match parts:
    case (entries, rest):
      (BandEntry{profile, V.Block{4294967295, 0, bottom}} <> entries, rest)

def init_band_entries(fuel: Nat, profiles: List<&2, V.Peq>,
                      +bottom: U32) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match fuel profiles:
    case 0n _:
      (Nil{}, profiles)
    case _ Nil{}:
      (Nil{}, Nil{})
    case 1n+p profile <> tail:
      init_band_entries.step(init_band_entries(p, tail, U32.add(bottom, 32)), profile, bottom)

def init_band.step(parts: List<&2, BandEntry> & List<&2, V.Peq>) -> Band:
  match parts:
    case (entries, rest):
      Band{0n, entries, rest}

def init_band(profiles: List<&2, V.Peq>, +length: Nat, +target_length: Nat,
              maximum: Nat) -> Band:
  # Called only after k >= target_length - length, with length <= target_length.
  count = Nat.min(V.ceil_div(length, 32n),
    V.ceil_div(1n+Nat.div(Nat.sub(maximum, Nat.sub(target_length, length)), 2n), 32n))
  init_band.step(init_band_entries(count, profiles, 32))

def advance_band.join(entry: BandEntry, updated: UpdatedBand) -> UpdatedBand:
  match updated:
    case UpdatedBand{entries, score, carry, bottom}:
      UpdatedBand{entry <> entries, score, carry, bottom}

def advance_band.last(result: V.Block & V.Carry, profile: V.Peq, bottom: Nat) -> UpdatedBand:
  match result:
    case (V.Block{+pv, +mv, +score}, carry):
      UpdatedBand{[BandEntry{profile, V.Block{pv, mv, score}}], score, carry, bottom}

def advance_band.next(result: V.Block & V.Carry, profile: V.Peq,
                      tail: V.Carry -> UpdatedBand) -> UpdatedBand:
  match result:
    case (next, carry):
      advance_band.join(BandEntry{profile, next}, tail(carry))

def advance_band(entries: List<&2, BandEntry>, +symbol: U32,
                 hin: V.Carry, +bottom: Nat) -> UpdatedBand:
  match entries:
    case Nil{}:
      UpdatedBand{Nil{}, 0, V.Carry{1, 0}, bottom}
    case BandEntry{+profile, block} <> Nil{}:
      advance_band.last(V.calculate_block(block,
        V.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin), profile, bottom)
    case BandEntry{+profile, block} <> tail:
      advance_band.next(V.calculate_block(block,
        V.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin), profile,
        carry => advance_band(tail, symbol, carry, Nat.add(bottom, 32n)))

# Edlib's conservative Ukkonen block bounds, rearranged so every term is
# nonnegative Nat arithmetic. Rows/columns here count consumed characters.
# The 62/63 constants adapt 2*WORD_SIZE-2/-1 from the pinned 64-bit code.
def band_keep_last(+score: Nat, bottom: Nat, +maximum: Nat,
                   length: Nat, target_length: Nat, column: Nat) -> Bool:
  Bool.and(Nat.is_lt(score, Nat.add(maximum, 32n)),
    Nat.is_le(Nat.add(Nat.add(bottom, score), target_length),
      Nat.add(Nat.add(Nat.add(maximum, length), column), 63n)))

def band_keep_first(+score: Nat, bottom: Nat, +maximum: Nat,
                    length: Nat, target_length: Nat, column: Nat) -> Bool:
  Bool.and(Nat.is_lt(score, Nat.add(maximum, 32n)),
    Nat.is_ge(Nat.add(Nat.add(bottom, maximum), target_length),
      Nat.add(Nat.add(score, length), column)))

def trim_last.choose(entry: BandEntry, entries: List<&2, BandEntry>, rest: List<&2, V.Peq>,
                     keep: Bool) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match entry entries keep:
    case BandEntry{profile, _} Nil{} False{}:
      (Nil{}, profile <> rest)
    case _ _ _:
      (entry <> entries, rest)

def trim_last.join(entry: BandEntry, tail: List<&2, BandEntry> & List<&2, V.Peq>,
                   keep: Bool) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match tail:
    case (entries, rest):
      trim_last.choose(entry, entries, rest, keep)

def trim_last(entries: List<&2, BandEntry>, rest: List<&2, V.Peq>, +bottom: Nat,
              +maximum: Nat, +length: Nat, +target_length: Nat,
              +column: Nat) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match entries:
    case Nil{}:
      (Nil{}, rest)
    case BandEntry{profile, V.Block{pv, mv, +score}} <> tail:
      trim_last.join(BandEntry{profile, V.Block{pv, mv, score}},
        trim_last(tail, rest, Nat.add(bottom, 32n), maximum, length, target_length, column),
        band_keep_last(U32.to_nat(score), bottom, maximum, length, target_length, column))

def trim_first.step(entry: BandEntry, tail: List<&2, BandEntry>, rest: List<&2, V.Peq>,
                    first: Nat, keep: Bool, next: Unit -> Band) -> Band:
  match keep:
    case True{}:
      Band{first, entry <> tail, rest}
    case False{}:
      next(Unit{})

def trim_first(entries: List<&2, BandEntry>, +rest: List<&2, V.Peq>, +first: Nat,
               +maximum: Nat, +length: Nat, +target_length: Nat,
               +column: Nat) -> Band:
  match entries:
    case Nil{}:
      Band{first, Nil{}, rest}
    case BandEntry{profile, V.Block{pv, mv, +score}} <> +tail:
      trim_first.step(BandEntry{profile, V.Block{pv, mv, score}}, tail, rest,
        first,
        band_keep_first(U32.to_nat(score), Nat.mul(1n+first, 32n),
          maximum, length, target_length, column),
        _ => trim_first(tail, rest, 1n+first, maximum, length, target_length, column))

def reduce_band.step(parts: List<&2, BandEntry> & List<&2, V.Peq>, first: Nat,
                     +maximum: Nat, length: Nat, target_length: Nat,
                     column: Nat, work: Nat) -> BandStep:
  match parts:
    case (entries, rest):
      BandStep{trim_first(entries, rest, first, maximum, length, target_length, column), maximum, work}

def reduce_band(entries: List<&2, BandEntry>, rest: List<&2, V.Peq>, +first: Nat,
                +maximum: Nat, +length: Nat, +target_length: Nat,
                +column: Nat, work: Nat) -> BandStep:
  reduce_band.step(trim_last(entries, rest, Nat.mul(1n+first, 32n),
    maximum, length, target_length, column), first, maximum, length, target_length, column, work)

def expand_band.step(result: V.Block & V.Carry, entries: List<&2, BandEntry>, profile: V.Peq,
                     rest: List<&2, V.Peq>, first: Nat, maximum: Nat, length: Nat,
                     target_length: Nat, column: Nat, work: Nat) -> BandStep:
  match result:
    case (block, _):
      reduce_band(List.append(&2, BandEntry, entries, [BandEntry{profile, block}]),
        rest, first, maximum, length, target_length, column, 1n+work)

def expand_band(entries: List<&2, BandEntry>, rest: List<&2, V.Peq>, +score: U32,
                carry: V.Carry, +symbol: U32, first: Nat, +maximum: Nat,
                length: Nat, target_length: Nat, column: Nat,
                work: Nat, expand: Bool) -> BandStep:
  match rest carry expand:
    case +profile <> tail V.Carry{+positive, +negative} True{}:
      previous = U32.add(U32.sub(U32.add(score, negative), positive), 32)
      expand_band.step(V.calculate_block(V.Block{4294967295, 0, previous},
        V.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), V.Carry{positive, negative}),
        entries, profile, tail, first, maximum, length, target_length, column, work)
    case _ _ _:
      reduce_band(entries, rest, first, maximum, length, target_length, column, work)

def band_step.updated(updated: UpdatedBand, rest: List<&2, V.Peq>, +first: Nat,
                      symbol: U32, +length: Nat, +target_length: Nat,
                      +column: Nat, maximum: Nat, padding: Nat) -> BandStep:
  match updated:
    case UpdatedBand{entries, +score, carry, +bottom}:
      # Completing the suffix by edits bounds the optimum. Padding can lower
      # the stored bottom score, so add it back before tightening k.
      +k = Nat.min(maximum, Nat.add(U32.to_nat(score),
        Nat.add(Nat.max(Nat.sub(target_length, column), Nat.sub(length, bottom)),
          Bool.pick(Nat, Nat.is_ge(bottom, length), padding, 0n))))
      work = Nat.sub(Nat.div(bottom, 32n), first)
      expand_band(entries, rest, score, carry, symbol, first, k, length, target_length,
        column, work, Nat.is_le(Nat.add(Nat.add(bottom, U32.to_nat(score)), target_length),
          Nat.add(Nat.add(Nat.add(k, length), column), 62n)))

def band_step(band: Band, +symbol: U32, length: Nat, target_length: Nat,
              column: Nat, maximum: Nat, padding: Nat) -> BandStep:
  match band:
    case Band{+first, entries, rest}:
      band_step.updated(advance_band(entries, symbol, V.Carry{1, 0}, Nat.mul(1n+first, 32n)),
        rest, first, symbol, length, target_length, column, maximum, padding)

def band_last_score(entries: List<&2, BandEntry>, +padding: Nat) -> Nat:
  match entries:
    case Nil{}:
      0n
    case BandEntry{_, V.Block{pv, mv, score}} <> Nil{}:
      U32.to_nat(V.get_block_cell_value(padding, pv, mv, score))
    case _ <> tail:
      band_last_score(tail, padding)

def band_finish(band: Band, maximum: Nat, padding: Nat,
                blocks: Nat, columns: Nat) -> Search:
  match band:
    case Band{_, Nil{}, _}:
      Search{E.NotFound{}, blocks, columns, 1n}
    case Band{_, entries, Nil{}}:
      +score = band_last_score(entries, padding)
      Search{Bool.pick(E.EditDistance, Nat.is_le(score, maximum), E.Found{score}, E.NotFound{}),
        blocks, columns, 1n}
    case _:
      Search{E.NotFound{}, blocks, columns, 1n}

def myers_calc_edit_distance_nw.step(step: BandStep, next: Band -> Nat -> Nat -> Search) -> Search:
  match step:
    case BandStep{band, maximum, work}:
      next(band, maximum, work)

def myers_calc_edit_distance_nw(target: String, band: Band, +length: Nat, +target_length: Nat,
                                maximum: Nat, +padding: Nat, +column: Nat, blocks: Nat) -> Search:
  match target band:
    case _ Band{_, Nil{}, _}:
      Search{E.NotFound{}, blocks, column, 1n}
    case SNil{} _:
      band_finish(band, maximum, padding, blocks, column)
    case SCon{h, t} _:
      myers_calc_edit_distance_nw.step(band_step(band, Char.to_u32(h), length, target_length,
        1n+column, maximum, padding), next => k => work =>
          myers_calc_edit_distance_nw(t, next, length, target_length, k, padding, 1n+column, Nat.add(blocks, work)))

def band_attempt(target: String, profiles: List<&2, V.Peq>, +length: Nat,
                 +target_length: Nat, +maximum: Nat, padding: Nat) -> Search:
  myers_calc_edit_distance_nw(target, init_band(profiles, length, target_length, maximum),
    length, target_length, maximum, padding, 0n, 0n)

def adaptive_search.step(distance: E.EditDistance, blocks: Nat, columns: Nat,
                         attempts: Nat, retry: Unit -> Search) -> Search:
  match distance:
    case E.Found{value}:
      Search{E.Found{value}, blocks, columns, attempts}
    case E.NotFound{}:
      retry(Unit{})

def adaptive_search.result(search: Search, blocks: Nat, columns: Nat, +attempts: Nat,
                           retry: Nat -> Nat -> Search) -> Search:
  match search:
    case Search{distance, work, consumed, _}:
      +next_blocks = Nat.add(blocks, work)
      +next_columns = Nat.add(columns, consumed)
      adaptive_search.step(distance, next_blocks, next_columns, 1n+attempts,
        _ => retry(next_blocks, next_columns))

def adaptive_search(fuel: Nat, +target: String, +profiles: List<&2, V.Peq>,
                    +length: Nat, +target_length: Nat, +maximum: Nat,
                    +padding: Nat, +blocks: Nat, +columns: Nat,
                    +attempts: Nat) -> Search:
  match fuel:
    case 0n:
      Search{E.NotFound{}, blocks, columns, attempts}
    case 1n+p:
      adaptive_search.result(band_attempt(target, profiles, length, target_length, maximum, padding),
        blocks, columns, attempts, bs => cs =>
          adaptive_search(p, target, profiles, length, target_length,
            Nat.min(target_length, Nat.mul(maximum, 2n)), padding, bs, cs, 1n+attempts))

def search_profiles(target: String, profiles: List<&2, V.Peq>, +length: Nat,
                    +target_length: Nat, threshold: E.Threshold) -> Search:
  match threshold:
    case E.MaxDistance{maximum}:
      band_attempt(target, profiles, length, target_length, Nat.min(maximum, target_length),
        Nat.sub(Nat.mul(V.ceil_div(length, 32n), 32n), length))
    case E.Unlimited{}:
      adaptive_search(1n+target_length, target, profiles, length, target_length,
        Nat.min(target_length, Nat.max(32n, Nat.sub(target_length, length))),
        Nat.sub(Nat.mul(V.ceil_div(length, 32n), 32n), length), 0n, 0n, 0n)

def search_query(+query: String, target: String, +length: Nat, target_length: Nat,
                 threshold: E.Threshold, pairs: List<&2, E.EqualityPair>,
                 rejected: Bool) -> Search:
  match rejected:
    case True{}:
      Search{E.NotFound{}, 0n, 0n, 0n}
    case False{}:
      search_profiles(target, V.build_peq(V.ceil_div(length, 32n), query, pairs), length, target_length, threshold)

def search_shorter(query: String, target: String, +query_length: Nat,
                   +target_length: Nat, +threshold: E.Threshold,
                   query_is_shorter: Bool, pairs: List<&2, E.EqualityPair>) -> Search:
  match query_is_shorter:
    case True{}:
      search_query(query, target, query_length, target_length, threshold, pairs,
        Bool.not(E.within_threshold(threshold, Nat.sub(target_length, query_length))))
    case False{}:
      search_query(target, query, target_length, query_length, threshold, pairs,
        Bool.not(E.within_threshold(threshold, Nat.sub(query_length, target_length))))

# Directional modes never swap query and target. The initial vertical scores
# are i in both modes, while the top horizontal difference is +1 for SHW and
# 0 for HW. NW's length/remaining-target band bounds do not apply here.
def semiglobal_carry(mode: E.Mode) -> V.Carry:
  match mode:
    case E.HW{}:
      V.Carry{0, 0}
    case _:
      V.Carry{1, 0}

def init_semiglobal_band(profiles: List<&2, V.Peq>, length: Nat, +maximum: Nat) -> Band:
  init_band.step(init_band_entries(
    Nat.min(V.ceil_div(length, 32n), V.ceil_div(1n+maximum, 32n)), profiles, 32))

# If the bottom score is >= k+32 every cell in that block is > k. Only
# trailing blocks are removed. HW always retains block zero: its free top
# boundary can seed a new alignment after an arbitrarily long target prefix.
def trim_semiglobal(entries: List<&2, BandEntry>, rest: List<&2, V.Peq>,
                    +mode: E.Mode, +index: Nat, +maximum: Nat) -> List<&2, BandEntry> & List<&2, V.Peq>:
  match entries mode:
    case Nil{} _:
      (Nil{}, rest)
    case BandEntry{profile, V.Block{pv, mv, +score}} <> tail E.HW{}:
      trim_last.join(BandEntry{profile, V.Block{pv, mv, score}},
        trim_semiglobal(tail, rest, mode, 1n+index, maximum),
        Bool.or(Nat.is_eq(index, 0n), Nat.is_lt(U32.to_nat(score), Nat.add(maximum, 32n))))
    case BandEntry{profile, V.Block{pv, mv, +score}} <> tail _:
      trim_last.join(BandEntry{profile, V.Block{pv, mv, score}},
        trim_semiglobal(tail, rest, mode, 1n+index, maximum),
        Nat.is_lt(U32.to_nat(score), Nat.add(maximum, 32n)))

def reduce_semiglobal(parts: List<&2, BandEntry> & List<&2, V.Peq>) -> Band:
  match parts:
    case (entries, rest):
      Band{0n, entries, rest}

def expand_semiglobal.result(result: V.Block & V.Carry, entries: List<&2, BandEntry>,
                              profile: V.Peq, rest: List<&2, V.Peq>, mode: E.Mode,
                              maximum: Nat) -> Band:
  match result:
    case (block, _):
      reduce_semiglobal(trim_semiglobal(
        List.append(&2, BandEntry, entries, [BandEntry{profile, block}]), rest, mode, 0n, maximum))

def expand_semiglobal.choose(entries: List<&2, BandEntry>, profile: V.Peq,
                             rest: List<&2, V.Peq>, previous: U32, eq: U32,
                             carry: V.Carry, mode: E.Mode, maximum: Nat, expand: Bool) -> Band:
  match expand:
    case True{}:
      expand_semiglobal.result(V.calculate_block(V.Block{4294967295, 0, U32.add(previous, 32)}, eq, carry),
        entries, profile, rest, mode, maximum)
    case False{}:
      reduce_semiglobal(trim_semiglobal(entries, profile <> rest, mode, 0n, maximum))

def expand_semiglobal(updated: UpdatedBand, rest: List<&2, V.Peq>, +symbol: U32,
                       mode: E.Mode, +maximum: Nat) -> Band:
  match updated rest:
    case UpdatedBand{entries, +score, V.Carry{+positive, +negative}, _} +profile <> tail:
      +previous = U32.sub(U32.add(score, negative), positive)
      +eq = V.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0))
      expand_semiglobal.choose(entries, profile, tail, previous, eq, V.Carry{positive, negative}, mode, maximum,
        Bool.and(Nat.is_le(U32.to_nat(previous), maximum),
          Bool.or(U32.is_ne(U32.and(eq, 1), 0), U32.is_ne(negative, 0))))
    case UpdatedBand{entries, _, _, _} Nil{}:
      reduce_semiglobal(trim_semiglobal(entries, Nil{}, mode, 0n, maximum))

def semiglobal_step(band: Band, +symbol: U32, +mode: E.Mode, maximum: Nat) -> Band:
  match band:
    case Band{_, entries, rest}:
      expand_semiglobal(advance_band(entries, symbol, semiglobal_carry(mode), 32n),
        rest, symbol, mode, maximum)

def semiglobal_endpoint(entries: List<&2, BandEntry>, rest: List<&2, V.Peq>, padding: Nat,
                         column: Nat, +best: A.Best) -> A.Best:
  match entries rest:
    case Nil{} _:
      best
    case _ Nil{}:
      A.Best{old, _} = best
      +score = U32.from_nat(band_last_score(entries, padding))
      A.update_best(best, score, A.Location{E.Position{column}, 0n}, U32.cmp(score, old))
    case _ _:
      best

def myers_calc_edit_distance_semiglobal.step(band: Band, padding: Nat, column: Nat,
                                             best: A.Best, next: Band -> A.Best -> A.Best) -> A.Best:
  match band:
    case Band{first, +entries, +rest}:
      next(Band{first, entries, rest}, semiglobal_endpoint(entries, rest, padding, column, best))

# Decode the real last query cell at every column, without Edlib's delayed
# padded endpoints. Tighten k after a better score, but continue for every tie.
def myers_calc_edit_distance_semiglobal(target: String, band: Band, +mode: E.Mode,
                                         +padding: Nat, +column: Nat, +maximum: Nat,
                                         +best: A.Best) -> A.Best:
  match target band:
    case _ Band{_, Nil{}, _}:
      A.ordered(best)
    case SNil{} _:
      A.ordered(best)
    case SCon{h, t} _:
      A.Best{score, _} = best
      +k = Nat.min(maximum, U32.to_nat(score))
      myers_calc_edit_distance_semiglobal.step(semiglobal_step(band, Char.to_u32(h), mode, k),
        padding, column, best, next => found =>
          myers_calc_edit_distance_semiglobal(t, next, mode, padding, 1n+column, k, found))

def semiglobal_initial_best(+length: Nat, include_before: Bool) -> A.Best:
  match include_before:
    case True{}:
      A.Best{U32.from_nat(length), [A.Location{E.BeforeStart{}, 0n}]}
    case False{}:
      A.Best{4294967295, Nil{}}

def semiglobal_maximum(threshold: E.Threshold, +length: Nat) -> Nat:
  match threshold:
    case E.Unlimited{}:
      length
    case E.MaxDistance{maximum}:
      Nat.min(maximum, length)

def semiglobal_best(target: String, profiles: List<&2, V.Peq>, +length: Nat,
                      +maximum: Nat, +mode: E.Mode) -> A.Best:
  +count = V.ceil_div(length, 32n)
  # Preserve pinned Edlib's 64-bit column-zero convention independently of
  # this implementation's 32-bit padding (especially lengths 32 and 96).
  best = semiglobal_initial_best(length, Nat.is_ne(Nat.mod(length, 64n), 0n))
  myers_calc_edit_distance_semiglobal(target,
    init_semiglobal_band(profiles, length, maximum), mode,
    Nat.sub(Nat.mul(count, 32n), length), 0n, maximum, best)

# Edlib selects the LAST optimal reverse-SHW end, hence the earliest start
# for each forward end. Preserve the special forward end -1 with start 0.
def hw_start(+end: Nat, reverse_location: A.Location) -> A.Location:
  match reverse_location:
    case A.Location{E.BeforeStart{}, _}:
      A.Location{E.Position{end}, 1n+end}
    case A.Location{E.Position{reverse_end}, _}:
      A.Location{E.Position{end}, Nat.sub(end, reverse_end)}

def hw_start_best(+end: Nat, best: A.Best) -> A.Location:
  match best:
    case A.Best{_, locations}:
      hw_start(end, Maybe.default(&2, A.Location,
        List.last(&2, A.Location, locations), A.Location{E.BeforeStart{}, 0n}))

def hw_location(location: A.Location, reverse_target: String, target_length: Nat,
                  profiles: List<&2, V.Peq>, query_length: Nat, maximum: Nat) -> A.Location:
  match location:
    case A.Location{E.BeforeStart{}, _}:
      A.Location{E.BeforeStart{}, 0n}
    case A.Location{E.Position{+end}, _}:
      hw_start_best(end, semiglobal_best(
        String.drop(reverse_target, Nat.sub(target_length, 1n+end)),
        profiles, query_length, maximum, E.SHW{}))

# Independent starts share one reversed query profile. Split their searches
# into balanced parallel branches, then concatenate in the original end order.
def hw_locations(fuel: Nat, locations: List<&2, A.Location>,
                   +reverse_target: String, +target_length: Nat,
                   +profiles: List<&2, V.Peq>, +query_length: Nat,
                   +maximum: Nat) -> List<&2, A.Location>:
  match fuel locations:
    case 0n _:
      locations
    case 1n+p Nil{}:
      Nil{}
    case 1n+p location <> Nil{}:
      [hw_location(location, reverse_target, target_length, profiles, query_length, maximum)]
    case Succ{+p} +values:
      +half = Nat.div(List.length(&2, A.Location, values), 2n)
      left right =
        hw_locations(p, List.take(&2, A.Location, values, half),
          reverse_target, target_length, profiles, query_length, maximum)
        hw_locations(p, List.drop(&2, A.Location, values, half),
          reverse_target, target_length, profiles, query_length, maximum)
      List.append(&2, A.Location, left, right)

def configured_found(task: E.Task, mode: E.Mode, +query: String, +target: String,
                        +pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
                        best: A.Best) -> E.AlignResult:
  match task mode best:
    case E.Distance{} _ _:
      A.result(query, target, task, pairs, format, best, True{})
    case _ E.HW{} A.Best{+score, +locations}:
      +qn +tn = S.length(query) S.length(target)
      rq rt = String.reverse(query) String.reverse(target)
      resolved = hw_locations(List.length(&2, A.Location, locations), locations,
        rt, tn, V.build_peq(V.ceil_div(qn, 32n), rq, pairs), qn, U32.to_nat(score))
      A.result(query, target, task, pairs, format, A.Best{score, resolved}, True{})
    case _ _ _:
      # NW/SHW always start at zero; only PATH needs reconstruction.
      A.result(query, target, task, pairs, format, best, True{})

def configured_result(query: String, target: String, mode: E.Mode, task: E.Task,
                         pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
                         best: A.Best, accepted: Bool) -> E.AlignResult:
  match accepted:
    case False{}:
      E.not_found()
    case True{}:
      configured_found(task, mode, query, target, pairs, format, best)

def configured_finish(query: String, target: String, mode: E.Mode, task: E.Task,
                         threshold: E.Threshold, pairs: List<&2, E.EqualityPair>,
                         format: E.CigarFormat, +best: A.Best) -> E.AlignResult:
  A.Best{score, _} = best
  configured_result(query, target, mode, task, pairs, format, best,
    E.within_threshold(threshold, U32.to_nat(score)))

def semiglobal_align(+query: String, +target: String, +mode: E.Mode, task: E.Task,
                       +threshold: E.Threshold, +pairs: List<&2, E.EqualityPair>,
                       format: E.CigarFormat) -> E.AlignResult:
  +length = S.length(query)
  configured_finish(query, target, mode, task, threshold, pairs, format,
    semiglobal_best(target, V.build_peq(V.ceil_div(length, 32n), query, pairs),
      length, semiglobal_maximum(threshold, length), mode))

def search_distance(search: Search) -> E.EditDistance:
  match search:
    case Search{distance, _, _, _}:
      distance

def found_value(distance: E.EditDistance) -> Nat:
  match distance:
    case E.Found{value}:
      value
    case E.NotFound{}:
      0n

def align_shorter(query: String, target: String, query_length: Nat,
                  target_length: Nat, query_is_shorter: Bool) -> Nat:
  found_value(search_distance(search_shorter(query, target, query_length,
    target_length, E.Unlimited{}, query_is_shorter, Nil{})))

def distance(query: String, target: String) -> Nat:
  match query target:
    case SNil{} _:
      S.length(target)
    case SCon{h, t} SNil{}:
      1n+S.length(t)
    case SCon{qh, qt} SCon{th, tt}:
      +q = {SCon{qh, qt} : String}
      +t = {SCon{th, tt} : String}
      +qn +tn = S.length(q) S.length(t)
      align_shorter(q, t, qn, tn, Nat.is_le(qn, tn))

def nw_result(query: String, target: String, task: E.Task,
                 pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
                 end: E.Coordinate, distance: E.EditDistance) -> E.AlignResult:
  match distance:
    case E.NotFound{}:
      E.not_found()
    case E.Found{score}:
      configured_result(query, target, E.NW{}, task, pairs, format,
        A.Best{U32.from_nat(score), [A.Location{end, 0n}]}, True{})

def edlib_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match query target config:
    case SNil{} _ _:
      A.empty_result("", target, config)
    case SCon{h, t} SNil{} _:
      A.empty_result(SCon{h, t}, "", config)
    case +q +t E.AlignConfig{E.NW{}, task, threshold, +pairs, format}:
      +qn +tn = S.length(q) S.length(t)
      nw_result(q, t, task, pairs, format, E.end_coordinate(tn),
        search_distance(search_shorter(q, t, qn, tn, threshold, Nat.is_le(qn, tn), pairs)))
    case +q +t E.AlignConfig{mode, task, threshold, pairs, format}:
      semiglobal_align(q, t, mode, task, threshold, pairs, format)

def response(query: String, target: String) -> String:
  Nat.show(distance(query, target))
