import Base
import ../main.bend as M
import ../EdlibTypes.bend as E
import ../AlignmentCli.bend as AC

# Test-only observability. All masks, transitions and decoded cells come from
# production defs; Python compares them with a scalar DP column, not a second
# transcription of the Myers bit formulas.
type Snapshot is Type:
  Snapshot{blocks: List<M.Block>, text: String}

def mask_rows(+depth: Nat, +query: String, +profile: M.Peq,
              +code: U32, +step: U32, +index: U32,
              +pairs: List<&2, E.EqualityPair>) -> String:
  match depth:
    case 0n:
      direct = M.build_peq_word(query, Chr{code}, 1, pairs)
      lookup = M.peq_get(profile, code, U32.is_ne(U32.and(code, 1), 0))
      "M," ++ U32.show(index) ++ "," ++ U32.show(code) ++ "," ++
        U32.show(direct) ++ "," ++ U32.show(lookup) ++ "\n"
    case 1n+p:
      low high = mask_rows(p, query, profile, code, U32.shl(step), index, pairs) mask_rows(p, query, profile, U32.add(code, step), U32.shl(step), index, pairs)
      low ++ high

def masks_words_step(parts: String & String, +profile: M.Peq,
                    tail: String -> String, index: U32,
                    pairs: List<&2, E.EqualityPair>) -> String:
  match parts:
    case (word, rest):
      mask_rows(8n, word, profile, 0, 1, index, pairs) ++ tail(rest)

# The continuation avoids mutual recursion, as in production build_peq.step.
def masks_words(profiles: List<&2, M.Peq>, query: String, +index: U32,
                 +pairs: List<&2, E.EqualityPair>) -> String:
  match profiles:
    case Nil{}:
      ""
    case +profile <> tail:
      masks_words_step(M.split_query(32n, query), profile,
        rest => masks_words(tail, rest, U32.add(index, 1), pairs), index, pairs)

def cell_values(fuel: Nat, +pv: U32, +mv: U32, +score: U32, +padding: Nat) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      "," ++ U32.show(M.get_block_cell_value(padding, pv, mv, score)) ++
        cell_values(p, pv, mv, score, 1n+padding)

def calculated_join(block: M.Block, carry: M.Carry, tail: Snapshot,
                    +column: U32, +index: U32) -> Snapshot:
  match block carry tail:
    case M.Block{+pv, +mv, +score} M.Carry{+hp, +hn} Snapshot{rest, text}:
      Snapshot{M.Block{pv, mv, score} <> rest,
        "B," ++ U32.show(column) ++ "," ++ U32.show(index) ++ "," ++
        U32.show(pv) ++ "," ++ U32.show(mv) ++ "," ++ U32.show(score) ++ "," ++
        U32.show(hp) ++ "," ++ U32.show(hn) ++ cell_values(32n, pv, mv, score, 0n) ++ "\n" ++ text}

def calculated_step(result: M.Block & M.Carry,
                    tail: M.Carry -> Snapshot, +column: U32, +index: U32) -> Snapshot:
  match result:
    case (next, +hout):
      calculated_join(next, hout, tail(hout), column, index)

def calculated(blocks: List<M.Block>, profiles: List<&2, M.Peq>, +symbol: U32,
               hin: M.Carry, +column: U32, +index: U32) -> Snapshot:
  match blocks profiles:
    case Nil{} _:
      Snapshot{Nil{}, ""}
    case _ Nil{}:
      Snapshot{Nil{}, ""}
    case block <> rest profile <> tail:
      calculated_step(
        M.calculate_block(block, M.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin),
        hout => calculated(rest, tail, symbol, hout, column, U32.add(index, 1)), column, index)

def dump_step(block: M.Block, tail: Snapshot, +column: U32, +index: U32) -> Snapshot:
  match block tail:
    case M.Block{+pv, +mv, +score} Snapshot{rest, text}:
      Snapshot{M.Block{pv, mv, score} <> rest,
        "A," ++ U32.show(column) ++ "," ++ U32.show(index) ++ "," ++
        U32.show(pv) ++ "," ++ U32.show(mv) ++ "," ++ U32.show(score) ++ "\n" ++ text}

def dump(blocks: List<M.Block>, +column: U32, +index: U32) -> Snapshot:
  match blocks:
    case Nil{}:
      Snapshot{Nil{}, ""}
    case block <> rest:
      dump_step(block, dump(rest, column, U32.add(index, 1)), column, index)

def trace_step(steps: Snapshot, columns: Snapshot,
               tail: List<M.Block> -> List<M.Block> -> String) -> String:
  match steps columns:
    case Snapshot{blocks, text} Snapshot{next, report}:
      text ++ report ++ tail(blocks, next)

def trace(target: String, +profiles: List<&2, M.Peq>,
          blocks: List<M.Block>, columns: List<M.Block>, +column: U32, +mode: E.Mode) -> String:
  match target:
    case SNil{}:
      ""
    case SCon{h, t}:
      +code = Char.to_u32(h)
      trace_step(
        calculated(blocks, profiles, code, M.semiglobal_carry(mode), column, 0),
        dump(M.advance_column(columns, profiles, code, M.semiglobal_carry(mode)), column, 0),
        bs => cs => trace(t, profiles, bs, cs, U32.add(column, 1), mode))

def trace_start(initial: Snapshot, +profiles: List<&2, M.Peq>,
                target: String, count: Nat, mode: E.Mode) -> String:
  match initial:
    case Snapshot{blocks, text}:
      text ++ trace(target, profiles, M.init_blocks(count, 32), blocks, 1, mode)

def trace_mode(+query: String, target: String, mode: Maybe<&2, E.Mode>) -> IO(Unit):
  match mode:
    case None{}:
      IO.die(Unit, 2, "Invalid mode")
    case Some{value}:
      +count = M.ceil_div(String.length(query), 32n)
      profiles = M.build_peq(count, query, Nil{})
      IO.print(trace_start(dump(M.init_blocks(count, 32), 0, 0), profiles, target, count, value))

def search_show(search: M.Search) -> String:
  match search:
    case M.Search{distance, blocks, columns, attempts}:
      E.distance_show(distance) ++ "," ++ Nat.show(blocks) ++ "," ++
        Nat.show(columns) ++ "," ++ Nat.show(attempts)

def search_run(+query: String, +target: String,
                threshold: Maybe<&2, E.Threshold>, pairs: List<&2, E.EqualityPair>) -> IO(Unit):
  match threshold:
    case None{}:
      IO.die(Unit, 2, "Invalid k")
    case Some{maximum}:
      +qn +tn = String.length(query) String.length(target)
      IO.print(search_show(M.search_shorter(query, target, qn, tn, maximum, Nat.is_le(qn, tn), pairs)))

def masks_run(+query: String, +pairs: List<&2, E.EqualityPair>) -> IO(Unit):
  count = Nat.max(1n, M.ceil_div(String.length(query), 32n))
  IO.print(masks_words(M.build_peq(count, query, pairs), query, 0, pairs))

def configured_masks(query: String, pairs: Maybe<&2, List<&2, E.EqualityPair>>) -> IO(Unit):
  match pairs:
    case None{}:
      IO.die(Unit, 2, "Invalid equality pairs")
    case Some{values}:
      masks_run(query, values)

def configured_search(query: String, target: String, threshold: Maybe<&2, E.Threshold>,
                       pairs: Maybe<&2, List<&2, E.EqualityPair>>) -> IO(Unit):
  match pairs:
    case None{}:
      IO.die(Unit, 2, "Invalid equality pairs")
    case Some{values}:
      search_run(query, target, threshold, values)

# Construct the entire byte domain inside Bend, including argv's unavailable NUL.
def byte_alphabet(fuel: Nat, +code: U32) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      SCon{Chr{code}, byte_alphabet(p, U32.add(code, 1))}

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "masks" <> +query <> Nil{}:
      masks_run(query, Nil{})
    case _ <> "masks-config" <> pairs <> query <> Nil{}:
      configured_masks(query, AC.read_pairs(pairs))
    case _ <> "masks-byte-pairs" <> Nil{}:
      masks_run(byte_alphabet(256n, 0), [E.EqualityPair{Chr{0}, Chr{255}},
        E.EqualityPair{Chr{127}, Chr{128}}, E.EqualityPair{Chr{128}, Chr{255}}])
    case _ <> "trace" <> +query <> target <> Nil{}:
      trace_mode(query, target, Some{E.NW{}})
    case _ <> "trace-mode" <> mode <> query <> target <> Nil{}:
      trace_mode(query, target, AC.read_mode(mode))
    case _ <> "search" <> k <> query <> target <> Nil{}:
      search_run(query, target, AC.read_threshold(k), Nil{})
    case _ <> "search-config" <> k <> pairs <> query <> target <> Nil{}:
      configured_search(query, target, AC.read_threshold(k), AC.read_pairs(pairs))
    case _:
      IO.die(Unit, 2, "Expected masks QUERY, masks-config PAIRS QUERY, masks-byte-pairs, trace QUERY TARGET, trace-mode MODE QUERY TARGET, search K QUERY TARGET or search-config K PAIRS QUERY TARGET")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
