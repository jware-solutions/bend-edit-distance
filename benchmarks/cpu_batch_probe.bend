import Base
import ../src/Batch.bend as B
import ../src/Transport.bend as BT
import ../EdlibTypes.bend as E
import ./gpu_metrics.bend as T

# A CPU-only executable keeps Bend's no-bang CPU scheduler optimizations.
# Compare the same prepared plan and restoration stages without a GPU bang.
type Work is Type:
  BatchReady{plan: B.Plan}
  BatchLate{first: E.AlignJob, sibling: E.AlignJob, plan: B.Plan}

# Benchmark control only: a costly first alignment delays a wide ready tree
# while the other outer branch finishes.
def prepare(mode: String, jobs: List<&2, E.AlignJob>) -> Work:
  match mode jobs:
    case "late" first <> sibling <> tail:
      BatchLate{first, sibling, B.prepare(tail)}
    case _ values:
      BatchReady{B.prepare(values)}

def delayed(first: E.AlignJob, plan: B.Plan) -> List<&2, B.IndexedResult>:
  value = B.single(0n, first)
  List.append(&2, B.IndexedResult, [value], B.execute(plan))

def offset(values: List<&2, B.IndexedResult>) -> List<&2, B.IndexedResult>:
  match values:
    case Nil{}:
      Nil{}
    case B.IndexedResult{index, result} <> tail:
      B.IndexedResult{Nat.add(index, 2n), result} <> offset(tail)

def restore_late(values: List<&2, B.IndexedResult>, sibling: B.IndexedResult) -> List<&2, B.IndexedResult>:
  match values:
    case Nil{}:
      [sibling]
    case first <> tail:
      first <> sibling <> offset(tail)

def execute(work: Work) -> List<&2, B.IndexedResult>:
  match work:
    case BatchReady{plan}:
      B.execute(plan)
    case BatchLate{first, sibling, plan}:
      a b = delayed(first, plan) B.single(1n, sibling)
      # delayed's first result already has index zero; only its tail came
      # from the separately indexed plan.
      restore_late(a, b)

def parsed(mode: String, count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural batch count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(n)
        work : Work <- T.begin(Work, False{}, prepare(mode, jobs))
        values : List<&2, B.IndexedResult> <- T.end(List<&2, B.IndexedResult>, execute(work))
        BT.write_batch(B.ordered(values))
        T.finish()

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "demand" <> count <> Nil{}:
      parsed("demand", Nat.read(count))
    case _ <> "late" <> count <> Nil{}:
      parsed("late", Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected demand|late COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
