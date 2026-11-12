import Base
import ../lib.bend as L
import ../Prepared.bend as Q
import ../EdlibTypes.bend as E
import ../src/PreparedPool.bend as P
import ../src/Transport.bend as BT
import ../GpuBatch.bend as G
import ./production_api.bend as API
import ./gate_metrics.bend as T

# Retained native CUDA attribution, distinct from the public BED2 lifecycle.
# Production preparation/cloning precedes the repeated complete API boundary;
# input decoding and output serialization retain the existing native timings.
def setup(count: Nat, repeat: Nat, shards: Nat, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match jobs:
    case E.AlignJob{query, _, E.AlignConfig{mode, task, threshold, pairs, format}} <> Nil{}:
      do IO<Unit>:
        T.reset()
        owner : Q.Prepared <- T.mark(Q.Prepared, 3, L.prepare(query, pairs))
        pool : P.Pool <- T.mark(P.Pool, 7, P.prepared(shards, Q.retained_bytes(owner)))
        saved : P.Pool <- API.inspect(pool)
        T.finish()
        API.rounds(~P.Pool, ~G.align_prepared_batch, repeat, count,
          Q.Options{mode, task, threshold, format}, saved)
    case _:
      IO.die(Unit, 2, "Expected query setup")

def parsed(count: Maybe<&2, Nat>, repeat: Maybe<&2, Nat>, shards: Maybe<&2, Nat>) -> IO(Unit):
  match count repeat shards:
    case Some{n} Some{r} Some{s}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(1n)
        setup(n, r, s, jobs)
    case _ _ _:
      IO.die(Unit, 2, "Expected string-batch COUNT ROUNDS OWNERS")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "string-batch" <> count <> repeat <> shards <> Nil{}:
      parsed(Nat.read(count), Nat.read(repeat), Nat.read(shards))
    case _:
      IO.die(Unit, 2, "Expected string-batch COUNT ROUNDS OWNERS")

def main() -> IO(Unit):
  do IO<Unit>:
    T.ready()
    args : List<String> <- IO.args()
    run(args)
