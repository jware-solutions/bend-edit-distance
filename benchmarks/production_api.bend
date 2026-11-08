import Base
import ../lib.bend as L
import ../Prepared.bend as Q
import ../EdlibTypes.bend as E
import ../src/PreparedPool.bend as P
import ../src/Transport.bend as BT
import ./gate_metrics.bend as T
import ./gate_input.bend as Input

def single_result(result: Q.Prepared & E.AlignResult) -> Q.Prepared & List<&2, E.AlignResult>:
  (next, value) = result
  (next, [value])

def single(owner: Q.Prepared, jobs: List<&2, String>, options: Q.Options) -> Q.Prepared & List<&2, E.AlignResult>:
  match jobs:
    case Nil{}:
      (owner, Nil{})
    case target <> Nil{}:
      single_result(L.align_prepared(owner, target, options))
    case _:
      (owner, Nil{})

def batch(pool: P.Pool, jobs: List<&2, String>, options: Q.Options) -> P.Pool & List<&2, E.AlignResult>:
  L.align_prepared_pool_batch(pool, jobs, options)

def serial_batch(owner: Q.Prepared, jobs: List<&2, String>, options: Q.Options) -> Q.Prepared & List<&2, E.AlignResult>:
  L.align_prepared_batch(owner, jobs, options)

def inspect(pool: P.Pool) -> IO(P.Pool):
  P.Pool{owners, +shards, length, budget} = pool
  T.owners(P.Pool, P.Pool{owners, shards, length, budget}, U32.from_nat(shards))

def written(~State: Type, result: State & List<&2, E.AlignResult>) -> IO(State):
  (next, values) = result
  do IO<State>:
    BT.write_batch(values)
    T.mark(Unit, 6, Unit{})
    T.finish()
    return next

def rounds(~State: Type, ~apply: State -> List<&2, String> -> Q.Options -> (State & List<&2, E.AlignResult>),
           fuel: Nat, +count: Nat, +options: Q.Options, state: State) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        jobs : List<&2, String> <- Input.read_targets(count)
        T.reset()
        result : State & List<&2, E.AlignResult> <- T.mark(State & List<&2, E.AlignResult>, 1, apply(state, jobs, options))
        next : State <- written(~State, result)
        rounds(~State, ~apply, p, count, options, next)

def prepared(mode: String, count: Nat, repeat: Nat, shards: Nat, options: Q.Options, owner: Q.Prepared) -> IO(Unit):
  match mode:
    case "string-single":
      do IO<Unit>:
        saved : Q.Prepared <- T.owners(Q.Prepared, owner, 1)
        T.finish()
        rounds(~Q.Prepared, ~single, repeat, count, options, saved)
    case "string-serial-batch":
      do IO<Unit>:
        saved : Q.Prepared <- T.owners(Q.Prepared, owner, 1)
        T.finish()
        rounds(~Q.Prepared, ~serial_batch, repeat, count, options, saved)
    case "string-batch":
      do IO<Unit>:
        pool : P.Pool <- T.mark(P.Pool, 7, P.prepared(shards, Q.retained_bytes(owner)))
        saved : P.Pool <- inspect(pool)
        T.finish()
        rounds(~P.Pool, ~batch, repeat, count, options, saved)
    case _:
      IO.die(Unit, 2, "Expected string-single or string-batch")

def start(mode: String, count: Nat, repeat: Nat, shards: Nat, job: E.AlignJob) -> IO(Unit):
  E.AlignJob{q, _, E.AlignConfig{m, task, k, pairs, format}} = job
  +options = {Q.Options{m, task, k, format} : Q.Options}
  do IO<Unit>:
    T.reset()
    owner : Q.Prepared <- T.mark(Q.Prepared, 3, L.prepare(q, pairs))
    prepared(mode, count, repeat, shards, options, owner)

def setup_jobs(mode: String, count: Nat, repeat: Nat, shards: Nat, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match jobs:
    case job <> Nil{}:
      start(mode, count, repeat, shards, job)
    case _:
      IO.die(Unit, 2, "Expected query setup")

def setup(mode: String, count: Nat, repeat: Nat, shards: Nat) -> IO(Unit):
  do IO<Unit>:
    jobs : List<&2, E.AlignJob> <- BT.read_batch(1n)
    setup_jobs(mode, count, repeat, shards, jobs)

def parsed(mode: String, count: Maybe<&2, Nat>, repeat: Maybe<&2, Nat>, shards: Maybe<&2, Nat>) -> IO(Unit):
  match count repeat shards:
    case Some{n} Some{r} Some{s}:
      setup(mode, n, r, s)
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

