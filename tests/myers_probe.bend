import ../src/Profile.bend as P
import ../src/BitVector.bend as V
import Base
import ../src/Myers.bend as M
import ../EdlibTypes.bend as E
import ../src/Cli.bend as AC

# Test-only observability. All masks, transitions and decoded cells come from
# production defs; Python compares them with a scalar DP column, not a second
# transcription of the Myers bit formulas.
type Snapshot is Type:
  Snapshot{blocks: List<V.Block>, text: String}

def mask_rows(+depth: Nat, +query: String, +profile: V.Peq,
              +code: U32, +step: U32, +index: U32,
              +pairs: List<&2, E.EqualityPair>) -> String:
  match depth:
    case 0n:
      direct = V.build_peq_word(query, Chr{code}, 1, pairs)
      lookup = V.peq_get(profile, code, U32.is_ne(U32.and(code, 1), 0))
      "M," ++ U32.show(index) ++ "," ++ U32.show(code) ++ "," ++
        U32.show(direct) ++ "," ++ U32.show(lookup) ++ "\n"
    case 1n+p:
      low high = mask_rows(p, query, profile, code, U32.shl(step), index, pairs) mask_rows(p, query, profile, U32.add(code, step), U32.shl(step), index, pairs)
      low ++ high

def masks_words_step(parts: String & String, +profile: V.Peq,
                    tail: String -> String, index: U32,
                    pairs: List<&2, E.EqualityPair>) -> String:
  match parts:
    case (word, rest):
      mask_rows(8n, word, profile, 0, 1, index, pairs) ++ tail(rest)

# The continuation avoids mutual recursion, as in production build_peq.step.
def masks_words(profiles: List<&2, V.Peq>, query: String, +index: U32,
                 +pairs: List<&2, E.EqualityPair>) -> String:
  match profiles:
    case Nil{}:
      ""
    case +profile <> tail:
      masks_words_step(V.split_query(32n, query), profile,
        rest => masks_words(tail, rest, U32.add(index, 1), pairs), index, pairs)

def cell_values(fuel: Nat, +pv: U32, +mv: U32, +score: U32, +padding: Nat) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      "," ++ U32.show(V.get_block_cell_value(padding, pv, mv, score)) ++
        cell_values(p, pv, mv, score, 1n+padding)

def calculated_join(block: V.Block, carry: V.Carry, tail: Snapshot,
                    +column: U32, +index: U32) -> Snapshot:
  match block carry tail:
    case V.Block{+pv, +mv, +score} V.Carry{+hp, +hn} Snapshot{rest, text}:
      Snapshot{V.Block{pv, mv, score} <> rest,
        "B," ++ U32.show(column) ++ "," ++ U32.show(index) ++ "," ++
        U32.show(pv) ++ "," ++ U32.show(mv) ++ "," ++ U32.show(score) ++ "," ++
        U32.show(hp) ++ "," ++ U32.show(hn) ++ cell_values(32n, pv, mv, score, 0n) ++ "\n" ++ text}

def calculated_step(result: V.Block & V.Carry,
                    tail: V.Carry -> Snapshot, +column: U32, +index: U32) -> Snapshot:
  match result:
    case (next, +hout):
      calculated_join(next, hout, tail(hout), column, index)

def calculated(blocks: List<V.Block>, profiles: List<&2, V.Peq>, +symbol: U32,
               hin: V.Carry, +column: U32, +index: U32) -> Snapshot:
  match blocks profiles:
    case Nil{} _:
      Snapshot{Nil{}, ""}
    case _ Nil{}:
      Snapshot{Nil{}, ""}
    case block <> rest profile <> tail:
      calculated_step(
        V.calculate_block(block, V.peq_get(profile, symbol, U32.is_ne(U32.and(symbol, 1), 0)), hin),
        hout => calculated(rest, tail, symbol, hout, column, U32.add(index, 1)), column, index)

def dump_step(block: V.Block, tail: Snapshot, +column: U32, +index: U32) -> Snapshot:
  match block tail:
    case V.Block{+pv, +mv, +score} Snapshot{rest, text}:
      Snapshot{V.Block{pv, mv, score} <> rest,
        "A," ++ U32.show(column) ++ "," ++ U32.show(index) ++ "," ++
        U32.show(pv) ++ "," ++ U32.show(mv) ++ "," ++ U32.show(score) ++ "\n" ++ text}

def dump(blocks: List<V.Block>, +column: U32, +index: U32) -> Snapshot:
  match blocks:
    case Nil{}:
      Snapshot{Nil{}, ""}
    case block <> rest:
      dump_step(block, dump(rest, column, U32.add(index, 1)), column, index)

def trace_step(steps: Snapshot, columns: Snapshot,
               tail: List<V.Block> -> List<V.Block> -> String) -> String:
  match steps columns:
    case Snapshot{blocks, text} Snapshot{next, report}:
      text ++ report ++ tail(blocks, next)

def trace(target: String, +profiles: List<&2, V.Peq>,
          blocks: List<V.Block>, columns: List<V.Block>, +column: U32, +mode: E.Mode) -> String:
  match target:
    case SNil{}:
      ""
    case SCon{h, t}:
      +code = Char.to_u32(h)
      trace_step(
        calculated(blocks, profiles, code, M.semiglobal_carry(mode), column, 0),
        dump(V.advance_column(columns, profiles, code, M.semiglobal_carry(mode)), column, 0),
        bs => cs => trace(t, profiles, bs, cs, U32.add(column, 1), mode))

def trace_start(initial: Snapshot, +profiles: List<&2, V.Peq>,
                target: String, count: Nat, mode: E.Mode) -> String:
  match initial:
    case Snapshot{blocks, text}:
      text ++ trace(target, profiles, V.init_blocks(count, 32), blocks, 1, mode)

def trace_mode(+query: String, target: String, mode: Maybe<&2, E.Mode>) -> IO(Unit):
  match mode:
    case None{}:
      IO.die(Unit, 2, "Invalid mode")
    case Some{value}:
      +count = V.ceil_div(String.length(query), 32n)
      profiles = V.build_peq(count, query, Nil{})
      IO.print(trace_start(dump(V.init_blocks(count, 32), 0, 0), profiles, target, count, value))

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
  count = Nat.max(1n, V.ceil_div(String.length(query), 32n))
  IO.print(masks_words(V.build_peq(count, query, pairs), query, 0, pairs))

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

def compact_masks.bits(+block: U32, +code: U32, query: String,
                       pairs: List<&2, E.EqualityPair>, result: P.Profile & U32) ->
                       P.Profile & String:
  (profile, mask) = result
  (profile, "M," ++ U32.show(block) ++ "," ++ U32.show(code) ++ "," ++
    U32.show(V.build_peq_word(query, Chr{code}, 1, pairs)) ++ "," ++ U32.show(mask) ++ "\n")

def compact_masks.row(+block: U32, code: U32, query: String,
                       pairs: List<&2, E.EqualityPair>, result: P.Profile & U32) -> P.Profile & String:
  (profile, row) = result
  compact_masks.bits(block, code, query, pairs, P.mask(profile, row, block))

def compact_masks.join(prefix: String, result: P.Profile & String) -> P.Profile & String:
  (profile, suffix) = result
  (profile, prefix ++ suffix)

def compact_masks(fuel: Nat, +query: String, +pairs: List<&2, E.EqualityPair>,
                    +block: U32, +code: U32, result: P.Profile & String) -> P.Profile & String:
  match fuel result:
    case 0n _:
      result
    case 1n+p Tuple{profile, text}:
      compact_masks.join(text, compact_masks(p, query, pairs, block, U32.inc(code),
        compact_masks.row(block, code, query, pairs, P.row(profile, code))))

def compact_words.step(rest: String, result: P.Profile & String,
                         next: String -> P.Profile -> String) -> String:
  (profile, text) = result
  text ++ next(rest, profile)

def compact_words.parts(+block: U32, pairs: List<&2, E.EqualityPair>,
                          parts: String & String, profile: P.Profile,
                          next: String -> P.Profile -> String) -> String:
  (word, rest) = parts
  compact_words.step(rest, compact_masks(256n, word, pairs, block, 0, (profile, "")), next)

def compact_words(fuel: Nat, query: String, +pairs: List<&2, E.EqualityPair>,
                    +block: U32, profile: P.Profile) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      compact_words.parts(block, pairs, V.split_query(32n, query), profile,
        rest => owned => compact_words(p, rest, pairs, U32.inc(block), owned))

def reference_search.choose(+query: String, target: String, +length: Nat, +columns: Nat,
                              threshold: E.Threshold, rejected: Bool) -> M.Search:
  match rejected:
    case True{}:
      M.Search{E.NotFound{}, 0n, 0n, 0n}
    case False{}:
      M.search_profiles(target, V.build_peq(V.ceil_div(length, 32n), query, Nil{}), length, columns, threshold)

def reference_search.orient(query: String, target: String, +qn: Nat, +tn: Nat,
                               +threshold: E.Threshold, shorter: Bool) -> M.Search:
  match shorter:
    case True{}:
      reference_search.choose(query, target, qn, tn, threshold,
        Bool.not(E.within_threshold(threshold, Nat.sub(tn, qn))))
    case False{}:
      reference_search.choose(target, query, tn, qn, threshold,
        Bool.not(E.within_threshold(threshold, Nat.sub(qn, tn))))

def reference_search(+query: String, +target: String, threshold: Maybe<&2, E.Threshold>) -> IO(Unit):
  match threshold:
    case None{}:
      IO.die(Unit, 2, "Invalid k")
    case Some{k}:
      +qn = String.length(query)
      +tn = String.length(target)
      IO.print(search_show(reference_search.orient(query, target, qn, tn, k, Nat.is_le(qn, tn))))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "compact" <> +query <> Nil{}:
      IO.print(compact_words(V.ceil_div(String.length(query), 32n), query, Nil{}, 0,
        P.build(query, String.length(query), Nil{})))
    case _ <> "compact-byte-pairs" <> Nil{}:
      +query = byte_alphabet(256n, 0)
      +pairs = {[E.EqualityPair{Chr{0}, Chr{255}}, E.EqualityPair{Chr{127}, Chr{128}}, E.EqualityPair{Chr{128}, Chr{255}}] : List<&2, E.EqualityPair>}
      IO.print(compact_words(8n, query, pairs, 0, P.build(query, 256n, pairs)))
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
    case _ <> "search-reference" <> k <> query <> target <> Nil{}:
      reference_search(query, target, AC.read_threshold(k))
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
