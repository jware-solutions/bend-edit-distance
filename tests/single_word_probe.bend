import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/Word.bend as Word
import ../src/SearchKernel.bend as K
import ../src/BitVector.bend as V
import ../src/Transport.bend as T

type Snapshot is Data:
  Snapshot{distance: E.EditDistance, pv: U32, mv: U32, score: U32, first: U32, last: U32}

def snapshot.block(distance: E.EditDistance, first: U32, last: U32,
                     value: W.Workspace & V.Block) -> Snapshot:
  (_, V.Block{pv, mv, score}) = value
  Snapshot{distance, pv, mv, score, first, last}

def snapshot(value: K.Run) -> Snapshot:
  K.Run{_, W.Workspace{data, capacity, +first, +last}, K.Stats{distance, _, _, _}} = value
  snapshot.block(distance, first, last, W.get(W.Workspace{data, capacity, first, last}, 0))

def same(a: Snapshot, b: Snapshot) -> Bool:
  Snapshot{_, ap, am, as, af, al} = a
  Snapshot{_, bp, bm, bs, bf, bl} = b
  Bool.and(Bool.and(U32.is_eq(ap, bp), U32.is_eq(am, bm)),
    Bool.and(U32.is_eq(as, bs), Bool.and(U32.is_eq(af, bf), U32.is_eq(al, bl))))

def distance(value: Snapshot) -> E.AlignResult:
  match value:
    case Snapshot{E.Found{d}, _, _, _, _, _}:
      E.distance_result(d, E.BeforeStart{}, True{})
    case _:
      E.not_found()

def results(+a: Snapshot, +b: Snapshot) -> List<&2, E.AlignResult>:
  [distance(a), distance(b), E.distance_result(Bool.pick(Nat, same(a, b), 1n, 0n), E.BeforeStart{}, True{})]

def run(value: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, +threshold, +pairs, _}} = value
  +length = String.length(query)
  +columns = String.length(target)
  results(snapshot(Q.run_nw(target, P.build(query, length, pairs), W.new(Word.blocks(length)), length, columns, threshold)),
    snapshot(K.search(target, P.build(query, length, pairs), W.new(Word.blocks(length)), length, columns, threshold)))

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    value : E.AlignJob <- T.job(request)
    T.write_batch(run(value))
