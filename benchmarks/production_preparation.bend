import Base
import ../lib.bend as L
import ../Prepared.bend as Q
import ../EdlibTypes.bend as E
import ../src/PreparedPool.bend as P
import ../src/Transport.bend as BT
import ./gate_metrics.bend as T
import ./gate_input.bend as Input
import ./production_api.bend as API

# Fresh production preparation in every round. Input conversion precedes the
# timer; disposal finishes before serialization. No legacy Peq construction.
def cycle.written(result: P.Pool & List<&2, E.AlignResult>) -> IO(Unit):
  (pool, values) = result
  do IO<Unit>:
    T.dispose(P.Pool, 4, pool)
    BT.write_batch(values)
    T.mark(Unit, 6, Unit{})
    T.finish()

def cloned(result: Q.Prepared & Q.Prepared) -> IO(Q.Prepared):
  (owner, other) = result
  do IO<Q.Prepared>:
    T.dispose(Q.Prepared, 2, other)
    return owner

def clone(owner: Q.Prepared, enabled: Bool) -> IO(Q.Prepared):
  match enabled:
    case False{}:
      IO.pure(Q.Prepared, owner)
    case True{}:
      do IO<Q.Prepared>:
        result : Q.Prepared & Q.Prepared <- T.mark(Q.Prepared & Q.Prepared, 0, Q.clone(owner))
        cloned(result)

def cycles(fuel: Nat, +cloning: Bool, +count: Nat, +shards: Nat, +query: String,
           +pairs: List<&2, E.EqualityPair>, +options: Q.Options) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        jobs : List<&2, String> <- Input.read_targets(count)
        T.reset()
        owner : Q.Prepared <- T.mark(Q.Prepared, 3, L.prepare(query, pairs))
        original : Q.Prepared <- clone(owner, cloning)
        pool : P.Pool <- T.mark(P.Pool, 7, P.prepared(shards, Q.retained_bytes(original)))
        saved : P.Pool <- API.inspect(pool)
        result : P.Pool & List<&2, E.AlignResult> <- T.mark(P.Pool & List<&2, E.AlignResult>, 1, API.batch(saved, jobs, options))
        cycle.written(result)
        cycles(p, cloning, count, shards, query, pairs, options)

def setup_job(cloning: Bool, count: Nat, repeat: Nat, shards: Nat, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match jobs:
    case E.AlignJob{q, _, E.AlignConfig{m, task, k, pairs, format}} <> Nil{}:
      do IO<Unit>:
        T.reset()
        T.finish()
        cycles(repeat, cloning, count, shards, q, pairs, Q.Options{m, task, k, format})
    case _:
      IO.die(Unit, 2, "Expected query setup")

def parsed(cloning: Bool, count: Maybe<&2, Nat>, repeat: Maybe<&2, Nat>, shards: Maybe<&2, Nat>) -> IO(Unit):
  match count repeat shards:
    case Some{n} Some{r} Some{s}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(1n)
        setup_job(cloning, n, r, s, jobs)
    case _ _ _:
      IO.die(Unit, 2, "Expected PREPARE-BATCH COUNT ROUNDS SHARDS")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "prepare-batch" <> count <> repeat <> shards <> Nil{}:
      parsed(False{}, Nat.read(count), Nat.read(repeat), Nat.read(shards))
    case _ <> "prepare-clone" <> count <> repeat <> shards <> Nil{}:
      parsed(True{}, Nat.read(count), Nat.read(repeat), Nat.read(shards))
    case _:
      IO.die(Unit, 2, "Expected PREPARE-BATCH COUNT ROUNDS SHARDS")

def main() -> IO(Unit):
  do IO<Unit>:
    T.ready()
    args : List<String> <- IO.args()
    run(args)
