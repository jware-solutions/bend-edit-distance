import Base
import ../EdlibTypes.bend as E
import ../src/BitVector.bend as V
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/Word.bend as Word
import ../src/Transport.bend as T

def measured(-A: Data, value: Array<A>) -> IO(Array<A> & Nat):
  import "./buffer_sizes.c"

def workspace.value(actual: Nat, expected: Nat, result: Array<V.Block> & V.Block) -> IO(Unit):
  (_, V.Block{positive, _, _}) = result
  IO.print("workspace," ++ Nat.show(actual) ++ "," ++ Nat.show(expected) ++ "," ++ U32.show(positive))

def workspace.measured(count: Nat, result: Array<V.Block> & Nat) -> IO(Unit):
  (array, actual) = result
  workspace.value(actual, W.storage_bytes(count), Array.get(V.Block, array, 0))

def workspace(count: Nat, value: W.Workspace) -> IO(Unit):
  W.Workspace{array, _, _, _} = value
  do IO<Unit>:
    result : Array<V.Block> & Nat <- measured(V.Block, array)
    workspace.measured(count, result)

def profile.report(actual: Nat, result: P.Profile & Nat) -> IO(Unit):
  (_, expected) = result
  IO.print("profile," ++ Nat.show(actual) ++ "," ++ Nat.show(expected))

def profile.masks(lookup: Array<U32>, stride: U32, rows: U32, blocks: U32, used: U32,
                    lookup_bytes: Nat, result: Array<U32> & Nat) -> IO(Unit):
  (masks, bytes) = result
  profile.report(Nat.add(lookup_bytes, bytes),
    P.retained_bytes(P.Profile{lookup, masks, stride, rows, blocks, used}))

def profile.lookup(masks: Array<U32>, stride: U32, rows: U32, blocks: U32, used: U32,
                     result: Array<U32> & Nat) -> IO(Unit):
  (lookup, bytes) = result
  do IO<Unit>:
    result : Array<U32> & Nat <- measured(U32, masks)
    profile.masks(lookup, stride, rows, blocks, used, bytes, result)

def profile(value: P.Profile) -> IO(Unit):
  P.Profile{lookup, masks, stride, rows, blocks, used} = value
  do IO<Unit>:
    result : Array<U32> & Nat <- measured(U32, lookup)
    profile.lookup(masks, stride, rows, blocks, used, result)

def run(job: E.AlignJob) -> IO(Unit):
  E.AlignJob{+query, _, E.AlignConfig{_, _, _, pairs, _}} = job
  +length = String.length(query)
  +count = Word.blocks(length)
  do IO<Unit>:
    workspace(count, W.new(count))
    profile(P.build(query, length, pairs))

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    run(job)
