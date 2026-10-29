import ./src/PreparedTransport.bend as PT
import ./src/PreparedPool.bend as P
import ./src/PoolTransport.bend as CPU
import ./Prepared.bend as Q
import Base
import ./GpuBatch.bend as G
import ./src/Transport.bend as BT
import ./EdlibTypes.bend as E

def prepared_many(pool: P.Pool, values: List<&2, BT.SizedTarget>, options: Q.Options) -> P.Pool & List<&2, E.AlignResult>:
  P.Pool{owners, shards, +length, budget} = pool
  +shared = options
  G.align_prepared_targets(P.Pool{owners, shards, length, budget},
    CPU.targets(values, 0n, length, shared), shared, True{})

def prepared_one(pool: P.Pool, target: BT.SizedTarget, options: Q.Options) -> P.Pool & E.AlignResult:
  P.single_result(prepared_many(pool, [target], options))

def parsed(count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural batch count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(n)
        BT.write_batch(G.align_batch(jobs))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      PT.serve_generic(~P.Pool, ~G.prepare_query, ~P.retained, ~prepared_one, ~prepared_many,
        ~G.align_single, ~G.align_batch)
    case _ <> count <> Nil{}:
      parsed(Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected COUNT or --worker with binary requests on stdin")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
