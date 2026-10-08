import Base

# The NW/distance path from vendor/edlib/edlib/src/edlib.cpp. Bend's native
# integer is U32, so a Myers word covers 32 query characters instead of 64.
# The CLI contract is ASCII, unit costs, and unlimited distance (k = -1).

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

# Unlimited NW evaluates every block once per target character. It needs
# only the current column; Ukkonen threshold bands and traceback storage
# are unnecessary for the distance-only, k = -1 interface.
def myers_calc_edit_distance_nw(target: String, +profiles: List<&2, Peq>,
                               blocks: List<Block>, +padding: Nat) -> Nat:
  match target:
    case SNil{}:
      last_block_score(blocks, padding)
    case SCon{h, t}:
      myers_calc_edit_distance_nw(t, profiles,
        advance_column(blocks, profiles, Char.to_u32(h), Carry{1, 0}), padding)

def align_query(+query: String, target: String, +length: Nat) -> Nat:
  +count = ceil_div(length, 32n)
  profiles = build_peq(count, query)
  blocks = init_blocks(count, 32)
  myers_calc_edit_distance_nw(target, profiles, blocks,
    Nat.sub(Nat.mul(count, 32n), length))

def align_shorter(query: String, target: String, query_length: Nat,
                  target_length: Nat, query_is_shorter: Bool) -> Nat:
  match query_is_shorter:
    case True{}:
      align_query(query, target, query_length)
    case False{}:
      align_query(target, query, target_length)

def edlib_align(query: String, target: String) -> Nat:
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

def response(query: String, target: String) -> String:
  Nat.show(edlib_align(query, target))

def run(args: List<String>) -> IO(Unit):
  match args:
    # IO.args includes argv[0]; the native runtime consumes flags before --.
    case Con{_, Con{query, Con{target, Nil{}}}}:
      IO.print(response(query, target))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
