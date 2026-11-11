import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../src/PreparedBytes.bend as PB
import ../src/ByteTarget.bend as BT
import ../src/Profile.bend as P
import ../src/Transport.bend as T
import ../src/Workspace.bend as W
import ../src/BitVector.bend as V
import ../src/Word.bend as Word
import ../src/SearchKernel.bend as K
import ../src/ByteKernel.bend as ByteK
import ../src/RetryHint.bend as Hint

def blocks.read(tail: W.Workspace -> List<V.Block>, value: W.Workspace & V.Block) -> List<V.Block>:
  (workspace, block) = value
  block <> tail(workspace)

def blocks(fuel: Nat, +index: U32, workspace: W.Workspace) -> List<V.Block>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      blocks.read(next => blocks(p, U32.inc(index), next), W.get(workspace, index))

def same_blocks(a: List<V.Block>, b: List<V.Block>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case V.Block{ap, am, as} <> at V.Block{bp, bm, bs} <> bt:
      Bool.and(Bool.and(U32.is_eq(ap, bp), Bool.and(U32.is_eq(am, bm), U32.is_eq(as, bs))),
        same_blocks(at, bt))
    case _ _:
      False{}

def exact(target: String, state: W.Updated) -> W.Workspace:
  match target state:
    case SNil{} W.Updated{_, workspace, _, _}:
      workspace
    case SCon{symbol, tail} W.Updated{profile, workspace, _, _}:
      exact(tail, W.column_reference(profile, workspace, Char.to_u32(symbol), V.Carry{1, 0}))

def workspace_result(+count: Nat, a: K.Run, b: W.Workspace) -> List<&2, E.AlignResult>:
  K.Run{_, W.Workspace{data, capacity, +first, +last}, _} = a
  good = Bool.and(Bool.and(U32.is_eq(first, 0), U32.is_eq(last, U32.from_nat(count))),
    same_blocks(blocks(count, 0, W.Workspace{data, capacity, first, last}), blocks(count, 0, b)))
  [E.distance_result(Bool.pick(Nat, good, 1n, 0n), E.BeforeStart{}, True{})]

def packed.byte(+index: U32, code: U32, value: Array<U32> & U32) -> Array<U32>:
  (bytes, word) = value
  bytes[U32.shrn(index, BT.log_cell_bytes())] <- U32.or(word,
    U32.shln(code, U32.to_nat(U32.shln(U32.and(index, 3), 3n))))

def packed.scan(sequence: String, +index: U32, bytes: Array<U32>) -> Array<U32>:
  match sequence:
    case SNil{}:
      bytes
    case SCon{symbol, tail}:
      packed.scan(tail, U32.inc(index), packed.byte(index, Char.to_u32(symbol),
        bytes[U32.shrn(index, BT.log_cell_bytes())]))

def packed(+sequence: String) -> BT.Target:
  +length = String.length(sequence)
  BT.Target{packed.scan(sequence, 0, Array.new(U32, P.depth(Nat.div(Nat.add(length, 3n), BT.cell_bytes())), 0)), length}

def compare(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>) -> List<&2, E.AlignResult>:
  [Q.result(PB.align(Q.prepare(query, pairs), packed(target))),
   Q.result(Q.align(Q.prepare(query, pairs), target, Q.default_options()))]

def reused(value: Q.Prepared & E.AlignResult) -> List<&2, E.AlignResult>:
  (prepared, result) = value
  [result, Q.result(PB.align(prepared, BT.Target{[65 : U32*1n], 1n}))]

def bounds.query(+query: String) -> List<&2, E.AlignResult>:
  List.append(&2, E.AlignResult,
    reused(PB.align(Q.prepare(query, Nil{}), BT.Target{[65 : U32*1n], 5n})),
    reused(PB.align(Q.prepare(query, Nil{}), BT.Target{[65 : U32*1n], 2147483648n})))

def bounds() -> List<&2, E.AlignResult>:
  bounds.query("A")

def same_words(a: List<U32>, b: List<U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      Bool.and(U32.is_eq(x, y), same_words(xs, ys))
    case _ _:
      False{}

# Consume every physical cell as well as metadata, including stale search state.
def profile_words(profile: P.Profile) -> List<U32>:
  P.Profile{lookup, masks, stride, rows, blocks, used} = profile
  stride <> rows <> blocks <> used <> List.append(&1, U32,
    Array.to_list(~U32, lookup), Array.to_list(~U32, masks))

def workspace_words(workspace: W.Workspace) -> List<V.Block>:
  W.Workspace{data, capacity, first, last} = workspace
  V.Block{capacity, first, last} <> Array.to_list(~V.Block, data)

type Saved is Type:
  Saved{profile: List<U32>, workspace: List<V.Block>}

def saved(owner: Q.Prepared) -> Saved:
  match owner:
    case Q.Prepared{_, _, _, Some{profile}, workspace}:
      Saved{profile_words(profile), workspace_words(workspace)}
    case _:
      Saved{Nil{}, Nil{}}

def same_saved(a: Saved, b: Saved) -> Bool:
  Saved{ap, aw} = a
  Saved{bp, bw} = b
  Bool.and(same_words(ap, bp), same_blocks(aw, bw))

def witness_checked(before: Saved, value: Q.Prepared & E.AlignResult) -> List<&2, E.AlignResult>:
  (after, result) = value
  good = same_saved(before, saved(after))
  [result, E.distance_result(Bool.pick(Nat, good, 1n, 0n), E.BeforeStart{}, True{})]

def witness_copied(target: String, query: String, pairs: List<&2, E.EqualityPair>, length: Nat,
                   +capacity: U32, +first: U32, +last: U32,
                   profiles: P.Profile & P.Profile, blocks: Array<V.Block> & Array<V.Block>) -> List<&2, E.AlignResult>:
  (profile, before_profile) = profiles
  (data, before_data) = blocks
  witness_checked(Saved{profile_words(before_profile), workspace_words(W.Workspace{before_data, capacity, first, last})},
    PB.align(Q.Prepared{query, pairs, length, Some{profile}, W.Workspace{data, capacity, first, last}}, packed(target)))

def witness_seeded(target: String, value: Q.Prepared & E.AlignResult) -> List<&2, E.AlignResult>:
  (owner, _) = value
  match owner:
    case Q.Prepared{query, pairs, length, Some{profile}, W.Workspace{data, capacity, first, last}}:
      witness_copied(target, query, pairs, length, capacity, first, last, P.clone(profile), Array.clone(V.Block, data))
    case _:
      [E.not_found(), E.not_found()]


def witness_hint(value: ByteK.HintRun) -> List<&2, E.AlignResult>:
  match value:
    case ByteK.HintRun{_, Hint.Hinted{_, Hint.Bounded{distance}}}:
      [E.distance_result(distance, E.BeforeStart{}, True{})]
    case _:
      [E.not_found()]

def witness_packed(+length: Nat, profile: P.Profile, target: BT.Target, complete: Bool) -> List<&2, E.AlignResult>:
  BT.Target{bytes, _} = target
  match complete:
    case False{}:
      witness_hint(ByteK.witness(length, profile, bytes))
    case True{}:
      witness_hint(ByteK.hint.scan(length, 0, 2n,
        ByteK.HintState{bytes, Hint.Scanning{profile, 0n, False{}}}))

def witness_probe(+query: String, target: String, pairs: List<&2, E.EqualityPair>, complete: Bool) -> List<&2, E.AlignResult>:
  +length = String.length(query)
  witness_packed(length, P.build(query, length, pairs), packed(target), complete)

def run(value: E.AlignJob, kind: String) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = value
  match kind:
    case "witness":
      witness_probe(query, target, pairs, False{})
    case "witness-math":
      witness_probe(query, target, pairs, True{})
    case "witness-owner":
      witness_seeded(target, Q.align(Q.prepare(query, pairs), "Z", Q.default_options()))
    case "workspace":
      +length = String.length(query)
      +count = Word.blocks(length)
      workspace_result(count,
        PB.run(packed(target), P.build(query, length, pairs), W.new(count), length,
          Nat.is_le(length, Word.width())),
        exact(target, W.Updated{P.build(query, length, pairs), W.initialize(W.new(count), count),
          0, V.Carry{1, 0}}))
    case "bounds":
      bounds()
    case "band-bounds":
      bounds.query(query)
    case "query":
      compare(SCon{Chr{256}, query}, target, pairs)
    case "pairs":
      compare(query, target, E.EqualityPair{Chr{256}, 'A'} <> pairs)
    case _:
      compare(query, target, pairs)

def args(values: List<String>, job: E.AlignJob) -> List<&2, E.AlignResult>:
  match values:
    case _ <> kind <> Nil{}:
      run(job, kind)
    case _:
      run(job, "byte")

def main() -> IO(Unit):
  do IO<Unit>:
    values : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(args(values, job))
