import Base
import ../lib.bend as L
import ../src/Batch.bend as B
import ../EdlibTypes.bend as E
import ../src/Transport.bend as BT

# Use production batch IO; keep plan observation local to this probe.
def plan_show(plan: B.Plan) -> String:
  match plan:
    case B.Empty{}:
      "null"
    case B.Leaf{index, job}:
      "{\"index\":" ++ Nat.show(index) ++ ",\"work\":" ++ F32.show(B.estimate(job)) ++ "}"
    case B.Fork{left, right}:
      "[" ++ plan_show(left) ++ "," ++ plan_show(right) ++ "]"
    case B.Serial{_}:
      "\"unexpected serial fallback\""

def compute(mode: String, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match mode:
    case "batch":
      BT.write_batch(L.align_batch(jobs))
    case "plan":
      IO.print(plan_show(B.prepare(jobs)))
    case _:
      IO.die(Unit, 2, "Expected batch or plan")

def parsed(mode: String, count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(n)
        compute(mode, jobs)

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> mode <> count <> Nil{}:
      parsed(mode, Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected MODE COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
