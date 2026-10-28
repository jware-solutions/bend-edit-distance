import ./src/PreparedTransport.bend as PT
import ./src/PreparedPool.bend as P
import Base
import ./GpuBatch.bend as G
import ./src/Transport.bend as BT
import ./EdlibTypes.bend as E

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
      PT.serve_generic(~P.Pool, ~G.prepare_query, ~P.retained, ~G.align_prepared_bytes, ~G.align_prepared_batch_bytes,
        ~G.align_single, ~G.align_batch)
    case _ <> count <> Nil{}:
      parsed(Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected COUNT or --worker with binary requests on stdin")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
