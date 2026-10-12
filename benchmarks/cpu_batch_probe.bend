import Base
import ../src/Batch.bend as B
import ../src/Transport.bend as BT
import ../EdlibTypes.bend as E
import ./gpu_metrics.bend as T

# A CPU-only executable keeps Bend's no-bang CPU scheduler optimizations.
# Compare the same prepared plan and restoration stages without a GPU bang.
def parsed(count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural batch count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(n)
        plan : B.Plan <- T.begin(B.Plan, False{}, B.prepare(jobs))
        values : List<&2, B.IndexedResult> <- T.end(List<&2, B.IndexedResult>, B.execute(plan))
        BT.write_batch(B.ordered(values))
        T.finish()

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "demand" <> count <> Nil{}:
      parsed(Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected demand COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
