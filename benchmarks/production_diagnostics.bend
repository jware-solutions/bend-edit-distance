import Base
import ../lib.bend as L
import ../Prepared.bend as Q
import ../EdlibTypes.bend as E
import ../src/PreparedPool.bend as P
import ../src/PreparedBytePool.bend as BP
import ../src/ByteTarget.bend as Own
import ../src/Transport.bend as BT
import ../src/SearchKernel.bend as K
import ../src/Alignment.bend as A
import ../src/Reconstruction.bend as R
import ../src/Myers.bend as M
import ../src/BitVector.bend as V
import ../src/Word.bend as Word
import ./gate_metrics.bend as T
import ./gate_input.bend as Input

# Intrusive composition of the SAME production pool primitives. This binary is
# compiled separately with allocation counters; it never supplies API samples.
type Counted is Type:
  Counted{plan: P.Plan, leaves: Nat}

def counted.join(a: Counted, b: Counted) -> Counted:
  Counted{left, n} = a
  Counted{right, m} = b
  Counted{P.Fork{left, right}, Nat.add(n, m)}

def counted(plan: P.Plan) -> Counted:
  match plan:
    case P.Leaf{owner, values}:
      Counted{P.Leaf{owner, values}, 1n}
    case P.Fork{left, right}:
      counted.join(counted(left), counted(right))

def observed(idle: List<Q.Prepared>, shards: Nat, length: Nat, budget: Nat, ordered: Bool,
             value: Counted) -> IO(P.PoolReady):
  Counted{plan, +leaves} = value
  T.leaves(P.PoolReady, P.PoolReady{plan, idle, shards, length, budget, ordered}, U32.from_nat(leaves))

def observe(ready: P.PoolReady) -> IO(P.PoolReady):
  P.PoolReady{plan, idle, shards, length, budget, ordered} = ready
  observed(idle, shards, length, budget, ordered, counted(plan))

type ByteCounted is Type:
  ByteCounted{plan: BP.Plan, leaves: Nat}

def byte_counted.join(a: ByteCounted, b: ByteCounted) -> ByteCounted:
  ByteCounted{left, n} = a
  ByteCounted{right, m} = b
  ByteCounted{BP.Fork{left, right}, Nat.add(n, m)}

def byte_counted(plan: BP.Plan) -> ByteCounted:
  match plan:
    case BP.Leaf{owner, values}:
      ByteCounted{BP.Leaf{owner, values}, 1n}
    case BP.Fork{left, right}:
      byte_counted.join(byte_counted(left), byte_counted(right))

def byte_observe(value: ByteCounted) -> IO(BP.Plan):
  ByteCounted{plan, leaves} = value
  T.leaves(BP.Plan, plan, U32.from_nat(leaves))

def byte_execute(shards: Nat, length: Nat, budget: Nat, +active: Nat, batch: Own.Batch,
                 parts: List<Q.Prepared> & List<Q.Prepared>) -> IO(P.Pool & List<&2, E.AlignResult>):
  Own.Batch{values, count, units, uniform} = batch
  (owners, idle) = parts
  do IO<P.Pool & List<&2, E.AlignResult>>:
    plan : BP.Plan <- T.mark(BP.Plan, 0,
      BP.branch(active, owners, active, values, count, units, U32.is_ne(uniform, 0)))
    observed : BP.Plan <- byte_observe(byte_counted(plan))
    done : BP.ByteDone <- T.mark(BP.ByteDone, 1, BP.execute(observed))
    T.mark(P.Pool & List<&2, E.AlignResult>, 2, BP.finish(idle, shards, length, budget, done))

def byte_ready(pool: P.Pool, batch: Own.Batch) -> IO(P.Pool & List<&2, E.AlignResult>):
  P.Pool{owners, +shards, +length, budget} = pool
  Own.Batch{values, +count, +units, uniform} = batch
  do IO<P.Pool & List<&2, E.AlignResult>>:
    +active : Nat <- T.mark(Nat, 8, BP.active_owners(shards, count, units, length))
    byte_execute(shards, length, budget, active, Own.Batch{values, count, units, uniform}, P.owners.split(active, owners))

def byte_request(pool: P.Pool, request: BT.Request) -> IO(P.Pool & List<&2, E.AlignResult>):
  match request:
    case BT.OwnedPreparedBatchRequest{_, batch}:
      do IO<P.Pool & List<&2, E.AlignResult>>:
        T.reset()
        byte_ready(pool, batch)
    case _:
      IO.die(P.Pool & List<&2, E.AlignResult>, 2, "Expected an owned diagnostic batch")


def targets(jobs: List<&2, E.AlignJob>) -> List<&2, String>:
  match jobs:
    case Nil{}:
      Nil{}
    case E.AlignJob{_, t, _} <> tail:
      t <> targets(tail)

def execute(ready: P.PoolReady, options: Q.Options) -> IO(P.Pool & List<&2, E.AlignResult>):
  P.PoolReady{plan, idle, shards, length, budget, ordered} = ready
  do IO<P.Pool & List<&2, E.AlignResult>>:
    result : P.PoolDone <- T.mark(P.PoolDone, 1, P.execute_known(False{}, plan, options))
    T.mark(P.Pool & List<&2, E.AlignResult>, 2, P.finish(idle, shards, length, budget, ordered, result))

def written(result: P.Pool & List<&2, E.AlignResult>) -> IO(P.Pool):
  (owner, values) = result
  do IO<P.Pool>:
    BT.write_batch(values)
    T.mark(Unit, 6, Unit{})
    T.finish()
    return owner

def byte_rounds(fuel: Nat, pool: P.Pool) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        request : BT.Request <- BT.read_owned_request()
        result : P.Pool & List<&2, E.AlignResult> <- byte_request(pool, request)
        next : P.Pool <- written(result)
        byte_rounds(p, next)

def rounds(fuel: Nat, +count: Nat, +options: Q.Options, pool: P.Pool) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- Input.read(count)
        T.reset()
        ready : P.PoolReady <- T.mark(P.PoolReady, 0, P.ready(pool, targets(jobs), options))
        measured : P.PoolReady <- observe(ready)
        result : P.Pool & List<&2, E.AlignResult> <- execute(measured, options)
        next : P.Pool <- written(result)
        rounds(p, count, options, next)

def inspect(pool: P.Pool) -> IO(P.Pool):
  P.Pool{owners, +shards, length, budget} = pool
  T.owners(P.Pool, P.Pool{owners, shards, length, budget}, U32.from_nat(shards))

# Serial restoration attribution. Slots 10/11/12 separate reversed inputs,
# legacy reverse profile construction, and every ordered endpoint recovery.
# Result construction includes CIGAR. No PATH-minus-DISTANCE subtraction.
def restore_best(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, task: E.Task,
                 format: E.CigarFormat, best: A.Best) -> IO(E.AlignResult):
  match task best:
    case E.Path{} A.Best{+score, +location <> tail}:
      do IO<E.AlignResult>:
        +segment : String <- T.mark(String, 13, A.span(target, location))
        +operations : List<&2, E.Operation> <- T.mark(List<&2, E.Operation>, 5,
          R.reconstruct_known(query, segment, pairs, U32.to_nat(score)))
        valid_location : Bool <- T.mark(Bool, 8, A.location_valid(target, location))
        valid_path : Bool <- T.mark(Bool, 8, R.valid_path(query, segment, operations, pairs, U32.to_nat(score)))
        T.mark(E.AlignResult, 9, A.path_checked(score, location <> tail, format,
          operations, Bool.and(valid_location, valid_path)))
    case _ _:
      T.mark(E.AlignResult, 9, A.result(query, target, task, pairs, format, best, True{}))

def restore(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, task: E.Task,
            format: E.CigarFormat, end: E.Coordinate, distance: E.EditDistance) -> IO(E.AlignResult):
  match distance:
    case E.Found{score}:
      restore_best(query, target, pairs, task, format, A.Best{U32.from_nat(score), [A.Location{end, 0n}]})
    case E.NotFound{}:
      T.mark(E.AlignResult, 9, E.not_found())

def hw_general(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, task: E.Task,
               format: E.CigarFormat, +score: U32, +locations: List<&2, A.Location>, +length: Nat) -> IO(E.AlignResult):
  do IO<E.AlignResult>:
    columns : Nat <- T.mark(Nat, 10, String.length(target))
    rq : String <- T.mark(String, 10, String.reverse(query))
    rt : String <- T.mark(String, 10, String.reverse(target))
    profiles : List<&2, V.Peq> <- T.mark(List<&2, V.Peq>, 11,
      V.build_peq(Word.blocks(length), rq, pairs))
    resolved : List<&2, A.Location> <- T.mark(List<&2, A.Location>, 12,
      M.hw_locations(List.length(&2, A.Location, locations), locations,
        rt, columns, profiles, length, U32.to_nat(score)))
    restore_best(query, target, pairs, task, format, A.Best{score, resolved})

def hw_restored(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, task: E.Task,
                format: E.CigarFormat, +score: U32, +locations: List<&2, A.Location>, +length: Nat,
                fixed: Bool) -> IO(E.AlignResult):
  match fixed:
    case True{}:
      do IO<E.AlignResult>:
        resolved : List<&2, A.Location> <- T.mark(List<&2, A.Location>, 12, M.hw_fixed(locations, length))
        restore_best(query, target, pairs, task, format, A.Best{score, resolved})
    case False{}:
      hw_general(query, target, pairs, task, format, score, locations, length)

def semi_accepted(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, task: E.Task,
                  mode: E.Mode, format: E.CigarFormat, +length: Nat, best: A.Best) -> IO(E.AlignResult):
  match task mode best:
    case E.Distance{} _ _:
      restore_best(query, target, pairs, task, format, best)
    case _ E.HW{} A.Best{+score, +locations}:
      hw_restored(query, target, pairs, task, format, score, locations, length,
        Bool.or(U32.is_eq(score, 0), Nat.is_eq(length, 1n)))
    case _ _ _:
      restore_best(query, target, pairs, task, format, best)

def semi_finish(query: String, target: String, pairs: List<&2, E.EqualityPair>, task: E.Task,
                mode: E.Mode, format: E.CigarFormat, length: Nat, best: A.Best, accepted: Bool) -> IO(E.AlignResult):
  match accepted:
    case True{}:
      semi_accepted(query, target, pairs, task, mode, format, length, best)
    case False{}:
      T.mark(E.AlignResult, 9, E.not_found())

def semi_restored(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, +length: Nat,
                  task: E.Task, +mode: E.Mode, threshold: E.Threshold, format: E.CigarFormat,
                  found: K.BestRun) -> IO(Q.Prepared & E.AlignResult):
  K.BestRun{profile, workspace, +best, _} = found
  A.Best{score, _} = best
  do IO<Q.Prepared & E.AlignResult>:
    accepted : Bool <- T.mark(Bool, 7, E.within_threshold(threshold, U32.to_nat(score)))
    value : E.AlignResult <- semi_finish(query, target, pairs, task, mode, format, length, best, accepted)
    return (Q.Prepared{query, pairs, length, Some{profile}, workspace}, value)

def restored(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, +length: Nat,
             columns: Nat, task: E.Task, format: E.CigarFormat, found: K.Run) -> IO(Q.Prepared & E.AlignResult):
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = found
  do IO<Q.Prepared & E.AlignResult>:
    value : E.AlignResult <- restore(query, target, pairs, task, format, E.end_coordinate(columns), distance)
    return (Q.Prepared{query, pairs, length, Some{profile}, workspace}, value)

def record_search_counts(value: K.Run) -> IO(K.Run):
  K.Run{profile, workspace, K.Stats{distance, +blocks, +columns, +attempts}} = value
  T.search_counts(K.Run, K.Run{profile, workspace, K.Stats{distance, blocks, columns, attempts}},
    U32.from_nat(blocks), U32.from_nat(columns), U32.from_nat(attempts),
    Bool.to_u32(Bool.and(Nat.is_le(blocks, 4294967295n),
      Bool.and(Nat.is_le(columns, 4294967295n), Nat.is_le(attempts, 4294967295n)))))

def search(owner: Q.Prepared, job: E.AlignJob) -> IO(Q.Prepared & E.AlignResult):
  match owner job:
    case prepared E.AlignJob{_, SNil{}, E.AlignConfig{mode, task, threshold, _, format}}:
      T.mark(Q.Prepared & E.AlignResult, 1, L.align_prepared(prepared, "", Q.Options{mode, task, threshold, format}))
    case Q.Prepared{query, pairs, +length, Some{profile}, workspace}
         E.AlignJob{_, +target, E.AlignConfig{E.NW{}, task, threshold, _, format}}:
      do IO<Q.Prepared & E.AlignResult>:
        columns : Nat <- T.mark(Nat, 7, String.length(target))
        +shared : Nat = columns
        found : K.Run <- T.mark(K.Run, 4, Q.run_nw(target, profile, workspace, length, shared, threshold))
        counted : K.Run <- record_search_counts(found)
        restored(query, target, pairs, length, shared, task, format, counted)
    case Q.Prepared{+query, +pairs, +length, Some{profile}, workspace}
         E.AlignJob{_, +target, E.AlignConfig{+mode, task, +threshold, _, format}}:
      do IO<Q.Prepared & E.AlignResult>:
        found : K.BestRun <- T.mark(K.BestRun, 4,
          K.best(target, profile, workspace, length, M.semiglobal_maximum(threshold, length), mode))
        uncounted : K.BestRun <- T.search_counts(K.BestRun, found, 0, 0, 0, 0)
        semi_restored(query, target, pairs, length, task, mode, threshold, format, uncounted)
    case prepared E.AlignJob{_, target, E.AlignConfig{mode, task, threshold, _, format}}:
      T.mark(Q.Prepared & E.AlignResult, 1, L.align_prepared(prepared, target, Q.Options{mode, task, threshold, format}))

def searches(jobs: List<&2, E.AlignJob>, state: Q.BatchState) -> IO(Q.Prepared & List<&2, E.AlignResult>):
  match jobs state:
    case Nil{} Q.BatchState{owner, results}:
      IO.pure(Q.Prepared & List<&2, E.AlignResult>, (owner, List.reverse(&2, E.AlignResult, results)))
    case job <> tail Q.BatchState{owner, results}:
      do IO<Q.Prepared & List<&2, E.AlignResult>>:
        result : Q.Prepared & E.AlignResult <- search(owner, job)
        searches(tail, Q.batch.updated(results, result))

def search_written(result: Q.Prepared & List<&2, E.AlignResult>) -> IO(Q.Prepared):
  (owner, values) = result
  do IO<Q.Prepared>:
    BT.write_batch(values)
    T.mark(Unit, 6, Unit{})
    T.finish()
    return owner

def search_rounds(fuel: Nat, +count: Nat, owner: Q.Prepared) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- Input.read(count)
        T.reset()
        result : Q.Prepared & List<&2, E.AlignResult> <- searches(jobs, Q.BatchState{owner, Nil{}})
        next : Q.Prepared <- search_written(result)
        search_rounds(p, count, next)

def prepared(mode: String, count: Nat, repeat: Nat, shards: Nat, options: Q.Options, owner: Q.Prepared) -> IO(Unit):
  match mode:
    case "owned-diagnostic":
      do IO<Unit>:
        pool : P.Pool <- T.mark(P.Pool, 7, P.prepared(shards, Q.retained_bytes(owner)))
        saved : P.Pool <- inspect(pool)
        T.finish()
        byte_rounds(repeat, saved)
    case "search-diagnostic":
      do IO<Unit>:
        saved : Q.Prepared <- T.owners(Q.Prepared, owner, 1)
        T.finish()
        search_rounds(repeat, count, saved)
    case _:
      do IO<Unit>:
        pool : P.Pool <- T.mark(P.Pool, 7, P.prepared(shards, Q.retained_bytes(owner)))
        saved : P.Pool <- inspect(pool)
        T.finish()
        rounds(repeat, count, options, saved)

def setup(mode: String, count: Nat, repeat: Nat, shards: Nat, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match jobs:
    case E.AlignJob{q, _, E.AlignConfig{m, task, k, pairs, format}} <> Nil{}:
      do IO<Unit>:
        T.reset()
        owner : Q.Prepared <- T.mark(Q.Prepared, 3, L.prepare(q, pairs))
        prepared(mode, count, repeat, shards, Q.Options{m, task, k, format}, owner)
    case _:
      IO.die(Unit, 2, "Expected query setup")

def parsed(mode: String, count: Maybe<&2, Nat>, repeat: Maybe<&2, Nat>, shards: Maybe<&2, Nat>) -> IO(Unit):
  match count repeat shards:
    case Some{n} Some{r} Some{s}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(1n)
        setup(mode, n, r, s, jobs)
    case _ _ _:
      IO.die(Unit, 2, "Expected MODE COUNT ROUNDS SHARDS")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> mode <> count <> repeat <> shards <> Nil{}:
      parsed(mode, Nat.read(count), Nat.read(repeat), Nat.read(shards))
    case _:
      IO.die(Unit, 2, "Expected MODE COUNT ROUNDS SHARDS")

def main() -> IO(Unit):
  do IO<Unit>:
    T.ready()
    args : List<String> <- IO.args()
    run(args)
