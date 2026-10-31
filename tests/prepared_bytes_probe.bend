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
      exact(tail, W.column(profile, workspace, Char.to_u32(symbol), V.Carry{1, 0}))

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

def bounds() -> List<&2, E.AlignResult>:
  List.append(&2, E.AlignResult,
    reused(PB.align(Q.prepare("A", Nil{}), BT.Target{[65 : U32*1n], 5n})),
    reused(PB.align(Q.prepare("A", Nil{}), BT.Target{[65 : U32*1n], 2147483648n})))

def run(value: E.AlignJob, kind: String) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = value
  match kind:
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
