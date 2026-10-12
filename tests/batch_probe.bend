import Base
import ../lib.bend as L
import ../Batch.bend as B
import ../EdlibTypes.bend as E
import ../BinaryTransport.bend as BT
import ../ByteProtocol.bend as P

# Test-only framing: gather exactly COUNT ordinary byte requests, then invoke
# the public pure batch API once. Production workers still serve single pairs.
def job(request: BT.Request) -> IO(E.AlignJob):
  match request:
    case BT.Bytes{m, t, k, f, qb, tb, eq}:
      IO.pure(E.AlignJob, E.AlignJob{P.byte_string(qb), P.byte_string(tb),
        E.AlignConfig{P.mode(m), P.task(t), P.threshold(k), P.pairs(eq), P.format(f)}})
    case _:
      IO.die(E.AlignJob, 2, "Expected a complete alignment request")

def read(count: Nat) -> IO(List<&2, E.AlignJob>):
  match count:
    case 0n:
      IO.pure(List<&2, E.AlignJob>, Nil{})
    case 1n+p:
      do IO<List<&2, E.AlignJob>>:
        request : BT.Request <- BT.read_request()
        head : E.AlignJob <- job(request)
        tail : List<&2, E.AlignJob> <- read(p)
        return head <> tail

def write(results: List<&2, E.AlignResult>) -> IO(Unit):
  match results:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        BT.write_response(P.encode(head))
        write(tail)

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
      write(L.align_batch(jobs))
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
        jobs : List<&2, E.AlignJob> <- read(n)
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
