import Base
import ../Batch.bend as B
import ../BatchIO.bend as BT
import ../GpuBatch.bend as G
import ../EdlibTypes.bend as E
import ./gpu_metrics.bend as T

def parsed(prefetch: Bool, count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural batch count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read(n)
        plan : B.Plan <- T.begin(B.Plan, prefetch, B.prepare(jobs))
        values : List<&2, B.IndexedResult> <- T.end(List<&2, B.IndexedResult>, G.execute(plan))
        BT.write(G.ordered(values))
        T.finish()

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "demand" <> count <> Nil{}:
      parsed(False{}, Nat.read(count))
    case _ <> "prefetch" <> count <> Nil{}:
      parsed(True{}, Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected demand|prefetch COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
