import ../src/Profile.bend as P
import ../src/BitVector.bend as V
import Base
import ../src/Myers.bend as M
import ../EdlibTypes.bend as E
import ../src/Cli.bend as AC
import ../src/Transport.bend as T

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

def profiled_search(+query: String, +target: String, threshold: Maybe<&2, E.Threshold>) -> IO(Unit):
  match threshold:
    case None{}:
      IO.die(Unit, 2, "Invalid k")
    case Some{k}:
      IO.print(search_show(M.search_shorter(query, target, String.length(query), String.length(target), k, True{}, Nil{})))

def decoded(padding: Maybe<&2, U32>, pv: Maybe<&2, U32>, mv: Maybe<&2, U32>, score: Maybe<&2, U32>) -> IO(Unit):
  match padding pv mv score:
    case Some{+pad} Some{+positive} Some{+negative} Some{+bottom}:
      IO.print(U32.show(V.get_block_cell_value(U32.to_nat(pad), positive, negative, bottom)) ++ "," ++
        U32.show(V.decode_word(U32.to_nat(pad), positive, negative, bottom)))
    case _ _ _ _:
      IO.die(Unit, 2, "Invalid decoder values")

# BED1 input admits NUL, arbitrary bytes and the maximum transport pair list.
# Mutating an explicit clone before dumping the source detects shared buffers.
def binary_mask.value(+block: U32, +code: U32, result: P.Profile & U32) -> P.Profile & String:
  (profile, bits) = result
  (profile, "B," ++ U32.show(block) ++ "," ++ U32.show(code) ++ "," ++ U32.show(bits) ++ "\n")

def binary_mask.row(+block: U32, code: U32, result: P.Profile & U32) -> P.Profile & String:
  (profile, row) = result
  binary_mask.value(block, code, P.mask(profile, row, block))

def binary_masks(fuel: Nat, +block: U32, +code: U32, result: P.Profile & String) -> P.Profile & String:
  match fuel result:
    case 0n _:
      result
    case 1n+p Tuple{profile, text}:
      compact_masks.join(text, binary_masks(p, block, U32.inc(code), binary_mask.row(block, code, P.row(profile, code))))

def binary_blocks(fuel: Nat, +count: Nat, +block: U32, result: P.Profile & String) -> P.Profile & String:
  match fuel result:
    case 0n _:
      result
    case 1n+p Tuple{profile, text}:
      compact_masks.join(text, binary_blocks(p, count, U32.inc(block),
        binary_masks(Bool.pick(Nat, Bool.or(Nat.is_le(count, 129n),
          Bool.or(U32.is_lt(block, 4), U32.is_ge(block, U32.from_nat(Nat.sub(count, 2n))))), 256n, 0n), block, 0, (profile, ""))))

def binary_dump(result: P.Profile & Nat) -> String:
  (profile, retained) = result
  P.Profile{lookup, masks, +stride, +rows, +blocks, +used} = profile
  "P," ++ U32.show(rows) ++ "," ++ U32.show(stride) ++ "," ++ U32.show(blocks) ++ "," ++
    U32.show(used) ++ "," ++ Nat.show(retained) ++ "\n" ++
    Pair.snd(P.Profile, String, binary_blocks(U32.to_nat(U32.inc(blocks)), U32.to_nat(blocks), 0,
      (P.Profile{lookup, masks, stride, rows, blocks, used}, "")))

def binary_clone_written(result: P.Profile & U32) -> String:
  (profile, row) = result
  U32.show(row) ++ "," ++ U32.show(Pair.snd(P.Profile, U32, P.mask(profile, 0, 0)))

def binary_cloned(result: P.Profile & P.Profile) -> IO(Unit):
  (original, other) = result
  P.Profile{lookup, masks, stride, rows, blocks, used} = other
  do IO<Unit>:
    # Force clone writes before reading the original; a dropped expression could
    # otherwise be eliminated by the compiler.
    IO.print(binary_clone_written(P.row(P.Profile{lookup[65] <- 4294967295,
      masks[0] <- 4294967295, stride, rows, blocks, used}, 65)))
    IO.print(binary_dump(P.retained_bytes(original)))

def binary_job(job: E.AlignJob) -> IO(Unit):
  E.AlignJob{+query, _, E.AlignConfig{_, _, _, +pairs, _}} = job
  binary_cloned(P.clone(P.build(query, String.length(query), pairs)))

def binary_input() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    binary_job(job)

# Poison physical spare cells so logical guards cannot pass merely because
# fresh unused capacity happened to contain zero.
def guards.value(+row: U32, +block: U32, text: String, result: P.Profile & U32) -> P.Profile & String:
  (profile, mask) = result
  (profile, text ++ U32.show(row) ++ "," ++ U32.show(block) ++ "," ++ U32.show(mask) ++ "\n")

def guards.step(+row: U32, +block: U32, result: P.Profile & String) -> P.Profile & String:
  (profile, text) = result
  guards.value(row, block, text, P.mask(profile, row, block))

def guards() -> String:
  Pair.snd(P.Profile, String, guards.step(4294967295, 2,
    guards.step(0, 2, guards.step(0, 3, guards.step(3, 0,
      (P.Profile{[0 : U32*256n], [4294967295 : U32*16n], 4, 3, 3, 1}, ""))))))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "compact-guards" <> Nil{}:
      IO.print(guards())
    case _ <> "compact-input" <> Nil{}:
      binary_input()
    case _ <> "decode" <> pad <> positive <> negative <> bottom <> Nil{}:
      decoded(U32.read(pad), U32.read(positive), U32.read(negative), U32.read(bottom))
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
    case _ <> "search-profiled" <> k <> query <> target <> Nil{}:
      profiled_search(query, target, AC.read_threshold(k))
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
