import Base
import ./Cli.bend as CLI
import ./EdlibTypes.bend as E
import ./Alignment.bend as A
import ./AlignmentCli.bend as AC

# The distance paths from vendor/edlib/edlib/src/edlib.cpp. Bend's native
# integer is U32, so a Myers word covers 32 query characters instead of 64.
# The scalar helper is NW, unit costs, unlimited distance (k = -1). The
# configured API extends it with the typed modes/tasks in EdlibTypes.bend.

type Peq is Data:
  Mask{bits: U32}
  Branch{low: Peq, high: Peq}

type Block is Data:
  Block{positive: U32, negative: U32, score: U32}

# Horizontal differences are -1, 0, or +1. Keep both signs explicit rather
# than relying on signed shifts or two's-complement arithmetic.
type Carry is Data:
  Carry{positive: U32, negative: U32}

def split_query.prepend(h: Char, parts: String & String) -> String & String:
  match parts:
    case (prefix, suffix):
      (SCon{h, prefix}, suffix)

def split_query(n: Nat, query: String) -> String & String:
  match n query:
    case 0n _:
      ("", query)
    case 1n+p SNil{}:
      ("", "")
    case 1n+p SCon{h, t}:
      split_query.prepend(h, split_query(p, t))

# Bit i matches query[i]. Unused high bits are wildcards, as in buildPeq.
def build_peq_word(query: String, +symbol: Char, +bit: U32) -> U32:
  match query:
    case SNil{}:
      U32.not(U32.sub(bit, 1))
    case SCon{h, t}:
      (U32.mul(Bool.to_u32(Char.is_eq(h, symbol)), bit) .|.
        build_peq_word(t, symbol, U32.shl(bit)) : U32)

# A byte-indexed immutable table replaces the C++ transformed alphabet.
# Low bits select branches, so lookup takes eight steps for every byte.
# Both halves of the table have equal, independent work and run in parallel.
def build_peq_table(+depth: Nat, +query: String, +symbol: U32, +step: U32) -> Peq:
  match depth:
    case 0n:
      Mask{build_peq_word(query, Chr{symbol}, 1)}
    case 1n+p:
      low high = build_peq_table(p, query, symbol, U32.shl(step)) build_peq_table(p, query, U32.add(symbol, step), U32.shl(step))
      Branch{low, high}

def peq_get(table: Peq, +code: U32, bit: Bool) -> U32:
  match table bit:
    case Mask{bits} _:
      bits
    case Branch{low, high} True{}:
      +next = U32.shr(code)
      peq_get(high, next, U32.is_ne(U32.and(next, 1), 0))
    case Branch{low, high} False{}:
      +next = U32.shr(code)
      peq_get(low, next, U32.is_ne(U32.and(next, 1), 0))

def build_peq.step(parts: String & String, tail: String -> List<&2, Peq>) -> List<&2, Peq>:
  match parts:
    case (word, rest):
      build_peq_table(8n, word, 0, 1) <> tail(rest)

def build_peq(fuel: Nat, query: String) -> List<&2, Peq>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      build_peq.step(split_query(32n, query), rest => build_peq(p, rest))

def ceil_div(+x: Nat, +y: Nat) -> Nat:
  Nat.div(Nat.add(x, Nat.sub(y, 1n)), y)

def init_blocks(n: Nat, +bottom: U32) -> List<Block>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Block{4294967295, 0, bottom} <> init_blocks(p, U32.add(bottom, 32))

# calculateBlock / Advance_Block from Myers. Addition intentionally wraps
# at 32 bits. Xv uses the original Eq, before the negative carry is added.
def calculate_block(block: Block, +eq: U32, hin: Carry) -> Block & Carry:
  Block{+pv, +mv, score} = block
  Carry{hin_positive, +hin_negative} = hin
  +xv = U32.or(eq, mv)
  +eq_in = U32.or(eq, hin_negative)
  +xh = (U32.xor(U32.add(U32.and(eq_in, pv), pv), pv) .|. eq_in : U32)
  +ph = U32.or(mv, U32.not(U32.or(xh, pv)))
  +mh = U32.and(pv, xh)
  +hout_positive = U32.shrn(ph, 31n)
  +hout_negative = U32.shrn(mh, 31n)
  +ph_shifted = U32.or(U32.shl(ph), hin_positive)
  mh_shifted = U32.or(U32.shl(mh), hin_negative)
  next_pv = U32.or(mh_shifted, U32.not(U32.or(xv, ph_shifted)))
  next_mv = U32.and(ph_shifted, xv)
  (Block{next_pv, next_mv, U32.sub(U32.add(score, hout_positive), hout_negative)},
    Carry{hout_positive, hout_negative})

# A column and consecutive target columns depend on their predecessor;
# parallelizing those calls would violate the Myers carry dependency.
def advance_column.step(result: Block & Carry,
                        tail: Carry -> List<Block>) -> List<Block>:
  match result:
    case (next, hout):
      next <> tail(hout)

def advance_column(blocks: List<Block>, profiles: List<&2, Peq>, +symbol: U32,
                   hin: Carry) -> List<Block>:
  match blocks profiles:
    case Nil{} _:
      Nil{}
    case _ Nil{}:
      Nil{}
    case block <> rest profile <> tail:
      advance_column.step(
        calculate_block(block, peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin),
        hout => advance_column(rest, tail, symbol, hout))

# getBlockCellValues(block)[W], without constructing the other 31 cells.
# Walking up a row subtracts its positive vertical difference and adds its
# negative difference. W is always in 0..31, never a whole extra block.
def get_block_cell_value(padding: Nat, +pv: U32, +mv: U32, score: U32) -> U32:
  match padding:
    case 0n:
      score
    case 1n+p:
      get_block_cell_value(p, U32.shl(pv), U32.shl(mv),
        U32.add(U32.sub(score, U32.shrn(pv, 31n)), U32.shrn(mv, 31n)))

def last_block_score(blocks: List<Block>, +padding: Nat) -> Nat:
  match blocks:
    case Nil{}:
      0n
    case Block{pv, mv, score} <> Nil{}:
      U32.to_nat(get_block_cell_value(padding, pv, mv, score))
    case _ <> rest:
      last_block_score(rest, padding)

# An active entry owns its current block and shares its immutable profile.
# Dropped leading entries are never visited again. Trailing profiles remain
# available for expansion; retries share the full profile but reset all blocks.
type BandEntry is Data:
  BandEntry{profile: Peq, block: Block}

type Band is Type:
  Band{first: Nat, entries: List<&2, BandEntry>, rest: List<&2, Peq>}

type UpdatedBand is Type:
  UpdatedBand{entries: List<&2, BandEntry>, score: U32, carry: Carry, bottom: Nat}

type BandStep is Type:
  BandStep{band: Band, maximum: Nat, work: Nat}

# Work counts actual calculate_block calls, consumed columns and fresh attempts.
# The probe uses these production counters to verify pruning and retry behavior.
type Search is Data:
  Search{distance: E.EditDistance, blocks: Nat, columns: Nat, attempts: Nat}

def init_band_entries.step(parts: List<&2, BandEntry> & List<&2, Peq>,
                           profile: Peq, bottom: U32) -> List<&2, BandEntry> & List<&2, Peq>:
  match parts:
    case (entries, rest):
      (BandEntry{profile, Block{4294967295, 0, bottom}} <> entries, rest)

def init_band_entries(fuel: Nat, profiles: List<&2, Peq>,
                      +bottom: U32) -> List<&2, BandEntry> & List<&2, Peq>:
  match fuel profiles:
    case 0n _:
      (Nil{}, profiles)
    case _ Nil{}:
      (Nil{}, Nil{})
    case 1n+p profile <> tail:
      init_band_entries.step(init_band_entries(p, tail, U32.add(bottom, 32)), profile, bottom)

def init_band.step(parts: List<&2, BandEntry> & List<&2, Peq>) -> Band:
  match parts:
    case (entries, rest):
      Band{0n, entries, rest}

def init_band(profiles: List<&2, Peq>, +length: Nat, +target_length: Nat,
              maximum: Nat) -> Band:
  # Called only after k >= target_length - length, with length <= target_length.
  count = Nat.min(ceil_div(length, 32n),
    ceil_div(1n+Nat.div(Nat.sub(maximum, Nat.sub(target_length, length)), 2n), 32n))
  init_band.step(init_band_entries(count, profiles, 32))

def advance_band.join(entry: BandEntry, updated: UpdatedBand) -> UpdatedBand:
  match updated:
    case UpdatedBand{entries, score, carry, bottom}:
      UpdatedBand{entry <> entries, score, carry, bottom}

def advance_band.last(result: Block & Carry, profile: Peq, bottom: Nat) -> UpdatedBand:
  match result:
    case (Block{+pv, +mv, +score}, carry):
      UpdatedBand{[BandEntry{profile, Block{pv, mv, score}}], score, carry, bottom}

def advance_band.next(result: Block & Carry, profile: Peq,
                      tail: Carry -> UpdatedBand) -> UpdatedBand:
  match result:
    case (next, carry):
      advance_band.join(BandEntry{profile, next}, tail(carry))

def advance_band(entries: List<&2, BandEntry>, +symbol: U32,
                 hin: Carry, +bottom: Nat) -> UpdatedBand:
  match entries:
    case Nil{}:
      UpdatedBand{Nil{}, 0, Carry{1, 0}, bottom}
    case BandEntry{+profile, block} <> Nil{}:
      advance_band.last(calculate_block(block,
        peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin), profile, bottom)
    case BandEntry{+profile, block} <> tail:
      advance_band.next(calculate_block(block,
        peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin), profile,
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

def trim_last.choose(entry: BandEntry, entries: List<&2, BandEntry>, rest: List<&2, Peq>,
                     keep: Bool) -> List<&2, BandEntry> & List<&2, Peq>:
  match entry entries keep:
    case BandEntry{profile, _} Nil{} False{}:
      (Nil{}, profile <> rest)
    case _ _ _:
      (entry <> entries, rest)

def trim_last.join(entry: BandEntry, tail: List<&2, BandEntry> & List<&2, Peq>,
                   keep: Bool) -> List<&2, BandEntry> & List<&2, Peq>:
  match tail:
    case (entries, rest):
      trim_last.choose(entry, entries, rest, keep)

def trim_last(entries: List<&2, BandEntry>, rest: List<&2, Peq>, +bottom: Nat,
              +maximum: Nat, +length: Nat, +target_length: Nat,
              +column: Nat) -> List<&2, BandEntry> & List<&2, Peq>:
  match entries:
    case Nil{}:
      (Nil{}, rest)
    case BandEntry{profile, Block{pv, mv, +score}} <> tail:
      trim_last.join(BandEntry{profile, Block{pv, mv, score}},
        trim_last(tail, rest, Nat.add(bottom, 32n), maximum, length, target_length, column),
        band_keep_last(U32.to_nat(score), bottom, maximum, length, target_length, column))

def trim_first.step(entry: BandEntry, tail: List<&2, BandEntry>, rest: List<&2, Peq>,
                    first: Nat, keep: Bool, next: Unit -> Band) -> Band:
  match keep:
    case True{}:
      Band{first, entry <> tail, rest}
    case False{}:
      next(Unit{})

def trim_first(entries: List<&2, BandEntry>, +rest: List<&2, Peq>, +first: Nat,
               +maximum: Nat, +length: Nat, +target_length: Nat,
               +column: Nat) -> Band:
  match entries:
    case Nil{}:
      Band{first, Nil{}, rest}
    case BandEntry{profile, Block{pv, mv, +score}} <> +tail:
      trim_first.step(BandEntry{profile, Block{pv, mv, score}}, tail, rest,
        first,
        band_keep_first(U32.to_nat(score), Nat.mul(1n+first, 32n),
          maximum, length, target_length, column),
        _ => trim_first(tail, rest, 1n+first, maximum, length, target_length, column))

def reduce_band.step(parts: List<&2, BandEntry> & List<&2, Peq>, first: Nat,
                     +maximum: Nat, length: Nat, target_length: Nat,
                     column: Nat, work: Nat) -> BandStep:
  match parts:
    case (entries, rest):
      BandStep{trim_first(entries, rest, first, maximum, length, target_length, column), maximum, work}

def reduce_band(entries: List<&2, BandEntry>, rest: List<&2, Peq>, +first: Nat,
                +maximum: Nat, +length: Nat, +target_length: Nat,
                +column: Nat, work: Nat) -> BandStep:
  reduce_band.step(trim_last(entries, rest, Nat.mul(1n+first, 32n),
    maximum, length, target_length, column), first, maximum, length, target_length, column, work)

def expand_band.step(result: Block & Carry, entries: List<&2, BandEntry>, profile: Peq,
                     rest: List<&2, Peq>, first: Nat, maximum: Nat, length: Nat,
                     target_length: Nat, column: Nat, work: Nat) -> BandStep:
  match result:
    case (block, _):
      reduce_band(List.append(&2, BandEntry, entries, [BandEntry{profile, block}]),
        rest, first, maximum, length, target_length, column, 1n+work)

def expand_band(entries: List<&2, BandEntry>, rest: List<&2, Peq>, +score: U32,
                carry: Carry, +symbol: U32, first: Nat, +maximum: Nat,
                length: Nat, target_length: Nat, column: Nat,
                work: Nat, expand: Bool) -> BandStep:
  match rest carry expand:
    case +profile <> tail Carry{+positive, +negative} True{}:
      previous = U32.add(U32.sub(U32.add(score, negative), positive), 32)
      expand_band.step(calculate_block(Block{4294967295, 0, previous},
        peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), Carry{positive, negative}),
        entries, profile, tail, first, maximum, length, target_length, column, work)
    case _ _ _:
      reduce_band(entries, rest, first, maximum, length, target_length, column, work)

def band_step.updated(updated: UpdatedBand, rest: List<&2, Peq>, +first: Nat,
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
      band_step.updated(advance_band(entries, symbol, Carry{1, 0}, Nat.mul(1n+first, 32n)),
        rest, first, symbol, length, target_length, column, maximum, padding)

def band_last_score(entries: List<&2, BandEntry>, +padding: Nat) -> Nat:
  match entries:
    case Nil{}:
      0n
    case BandEntry{_, Block{pv, mv, score}} <> Nil{}:
      U32.to_nat(get_block_cell_value(padding, pv, mv, score))
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

def band_attempt(target: String, profiles: List<&2, Peq>, +length: Nat,
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

def adaptive_search(fuel: Nat, +target: String, +profiles: List<&2, Peq>,
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

def search_profiles(target: String, profiles: List<&2, Peq>, +length: Nat,
                    +target_length: Nat, threshold: E.Threshold) -> Search:
  match threshold:
    case E.MaxDistance{maximum}:
      band_attempt(target, profiles, length, target_length, Nat.min(maximum, target_length),
        Nat.sub(Nat.mul(ceil_div(length, 32n), 32n), length))
    case E.Unlimited{}:
      adaptive_search(1n+target_length, target, profiles, length, target_length,
        Nat.min(target_length, Nat.max(32n, Nat.sub(target_length, length))),
        Nat.sub(Nat.mul(ceil_div(length, 32n), 32n), length), 0n, 0n, 0n)

def search_query(+query: String, target: String, +length: Nat, target_length: Nat,
                 threshold: E.Threshold, rejected: Bool) -> Search:
  match rejected:
    case True{}:
      Search{E.NotFound{}, 0n, 0n, 0n}
    case False{}:
      search_profiles(target, build_peq(ceil_div(length, 32n), query), length, target_length, threshold)

def search_shorter(query: String, target: String, +query_length: Nat,
                   +target_length: Nat, +threshold: E.Threshold,
                   query_is_shorter: Bool) -> Search:
  match query_is_shorter:
    case True{}:
      search_query(query, target, query_length, target_length, threshold,
        Bool.not(E.within_threshold(threshold, Nat.sub(target_length, query_length))))
    case False{}:
      search_query(target, query, target_length, query_length, threshold,
        Bool.not(E.within_threshold(threshold, Nat.sub(query_length, target_length))))

# Directional modes never swap query and target. The initial vertical scores
# are i in both modes, while the top horizontal difference is +1 for SHW and
# 0 for HW. NW's length/remaining-target band bounds do not apply here.
def semiglobal_carry(mode: E.Mode) -> Carry:
  match mode:
    case E.HW{}:
      Carry{0, 0}
    case _:
      Carry{1, 0}

def init_semiglobal_band(profiles: List<&2, Peq>, length: Nat, +maximum: Nat) -> Band:
  init_band.step(init_band_entries(
    Nat.min(ceil_div(length, 32n), ceil_div(1n+maximum, 32n)), profiles, 32))

# If the bottom score is >= k+32 every cell in that block is > k. Only
# trailing blocks are removed. HW always retains block zero: its free top
# boundary can seed a new alignment after an arbitrarily long target prefix.
def trim_semiglobal(entries: List<&2, BandEntry>, rest: List<&2, Peq>,
                    +mode: E.Mode, +index: Nat, +maximum: Nat) -> List<&2, BandEntry> & List<&2, Peq>:
  match entries mode:
    case Nil{} _:
      (Nil{}, rest)
    case BandEntry{profile, Block{pv, mv, +score}} <> tail E.HW{}:
      trim_last.join(BandEntry{profile, Block{pv, mv, score}},
        trim_semiglobal(tail, rest, mode, 1n+index, maximum),
        Bool.or(Nat.is_eq(index, 0n), Nat.is_lt(U32.to_nat(score), Nat.add(maximum, 32n))))
    case BandEntry{profile, Block{pv, mv, +score}} <> tail _:
      trim_last.join(BandEntry{profile, Block{pv, mv, score}},
        trim_semiglobal(tail, rest, mode, 1n+index, maximum),
        Nat.is_lt(U32.to_nat(score), Nat.add(maximum, 32n)))

def reduce_semiglobal(parts: List<&2, BandEntry> & List<&2, Peq>) -> Band:
  match parts:
    case (entries, rest):
      Band{0n, entries, rest}

def expand_semiglobal.result(result: Block & Carry, entries: List<&2, BandEntry>,
                              profile: Peq, rest: List<&2, Peq>, mode: E.Mode,
                              maximum: Nat) -> Band:
  match result:
    case (block, _):
      reduce_semiglobal(trim_semiglobal(
        List.append(&2, BandEntry, entries, [BandEntry{profile, block}]), rest, mode, 0n, maximum))

def expand_semiglobal.choose(entries: List<&2, BandEntry>, profile: Peq,
                             rest: List<&2, Peq>, previous: U32, eq: U32,
                             carry: Carry, mode: E.Mode, maximum: Nat, expand: Bool) -> Band:
  match expand:
    case True{}:
      expand_semiglobal.result(calculate_block(Block{4294967295, 0, U32.add(previous, 32)}, eq, carry),
        entries, profile, rest, mode, maximum)
    case False{}:
      reduce_semiglobal(trim_semiglobal(entries, profile <> rest, mode, 0n, maximum))

def expand_semiglobal(updated: UpdatedBand, rest: List<&2, Peq>, +symbol: U32,
                       mode: E.Mode, +maximum: Nat) -> Band:
  match updated rest:
    case UpdatedBand{entries, +score, Carry{+positive, +negative}, _} +profile <> tail:
      +previous = U32.sub(U32.add(score, negative), positive)
      +eq = peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0))
      expand_semiglobal.choose(entries, profile, tail, previous, eq, Carry{positive, negative}, mode, maximum,
        Bool.and(Nat.is_le(U32.to_nat(previous), maximum),
          Bool.or(U32.is_ne(U32.and(eq, 1), 0), U32.is_ne(negative, 0))))
    case UpdatedBand{entries, _, _, _} Nil{}:
      reduce_semiglobal(trim_semiglobal(entries, Nil{}, mode, 0n, maximum))

def semiglobal_step(band: Band, +symbol: U32, +mode: E.Mode, maximum: Nat) -> Band:
  match band:
    case Band{_, entries, rest}:
      expand_semiglobal(advance_band(entries, symbol, semiglobal_carry(mode), 32n),
        rest, symbol, mode, maximum)

def semiglobal_endpoint(entries: List<&2, BandEntry>, rest: List<&2, Peq>, padding: Nat,
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

def semiglobal_align(+query: String, +target: String, +mode: E.Mode,
                      +threshold: E.Threshold) -> E.AlignResult:
  +length = String.length(query)
  +count = ceil_div(length, 32n)
  +maximum = semiglobal_maximum(threshold, length)
  # Preserve pinned Edlib's 64-bit column-zero convention independently of
  # this implementation's 32-bit padding (especially lengths 32 and 96).
  best = semiglobal_initial_best(length, Nat.is_ne(Nat.mod(length, 64n), 0n))
  A.finish(query, target, E.Distance{}, threshold, Nil{}, E.Extended{},
    myers_calc_edit_distance_semiglobal(target,
      init_semiglobal_band(build_peq(count, query), length, maximum), mode,
      Nat.sub(Nat.mul(count, 32n), length), 0n, maximum, best))

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
    target_length, E.Unlimited{}, query_is_shorter)))

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
      align_shorter(q, t, qn, tn, Nat.is_le(qn, tn))

def threshold_result(distance: E.EditDistance, end: E.Coordinate) -> E.AlignResult:
  match distance:
    case E.NotFound{}:
      E.not_found()
    case E.Found{score}:
      E.distance_result(score, end, True{})

def edlib_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match query target config:
    case SNil{} _ _:
      A.align("", target, config)
    case SCon{h, t} SNil{} _:
      A.align(SCon{h, t}, "", config)
    case +q +t E.AlignConfig{E.NW{}, E.Distance{}, threshold, Nil{}, _}:
      +qn +tn = String.length(q) String.length(t)
      threshold_result(search_distance(search_shorter(q, t, qn, tn, threshold,
        Nat.is_le(qn, tn))), E.end_coordinate(tn))
    case +q +t E.AlignConfig{mode, E.Distance{}, threshold, Nil{}, _}:
      semiglobal_align(q, t, mode, threshold)
    case _ _ _:
      A.align(query, target, config)

def response(query: String, target: String) -> String:
  Nat.show(distance(query, target))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> query <> target <> Nil{}:
      CLI.run(~distance, ["bend-edit-distance", query, target])
    case _:
      AC.run(~edlib_align, args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
