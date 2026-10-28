import Base
import ../EdlibTypes.bend as E
import ./ByteProtocol.bend as P

# The native bridge returns lists of byte values, never decoded UTF-8 text.
type Request is Type:
  End{}
  Invalid{}
  Bytes{mode: U32, task: U32, threshold: U32, format: U32,
    query: List<U32>, target: List<U32>, equalities: List<U32>}
  PrepareRequest{query: List<U32>, equalities: List<U32>}
  PreparedRequest{handle: U32, mode: U32, task: U32, threshold: U32, format: U32, target: List<U32>}
  ReleaseRequest{handle: U32}
  BatchRequest{count: U32}
  PreparedBatchRequest{handle: U32, mode: U32, task: U32, threshold: U32, format: U32, targets: List<List<U32>>}
  InvalidControl{operation: U32}

def read_request() -> IO(Request):
  import "./transport.c"

def write_response(bytes: List<U32>) -> IO(Unit):
  import "./transport.c"

def respond(~align: String -> String -> E.AlignConfig -> E.AlignResult,
            request: Request) -> IO(Bool):
  match request:
    case End{}:
      IO.pure(Bool, False{})
    case Invalid{}:
      do IO<Bool>:
        write_response(P.encode(E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}))
        return True{}
    case Bytes{m, t, k, f, qb, tb, eq}:
      query target = P.byte_string(qb) P.byte_string(tb)
      do IO<Bool>:
        write_response(P.encode(align(query, target,
          E.AlignConfig{P.mode(m), P.task(t), P.threshold(k), P.pairs(eq), P.format(f)})))
        return True{}
    case _:
      do IO<Bool>:
        write_response(P.encode(E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}))
        return True{}

# Count down a very large Nat so the server remains termination-checked.
# EOF ends it immediately; no foreign or unsafe recursion enters the core.
def continue(alive: Bool, next: Unit -> IO(Unit)) -> IO(Unit):
  match alive:
    case True{}:
      next(Unit{})
    case False{}:
      IO.pure(Unit, Unit{})

def run(~align: String -> String -> E.AlignConfig -> E.AlignResult,
        fuel: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        request : Request <- read_request()
        alive : Bool <- respond(~align, request)
        continue(alive, _ => run(~align, p))

def serve(~align: String -> String -> E.AlignConfig -> E.AlignResult) -> IO(Unit):
  run(~align, 4294967295n)

# COUNT ordinary binary requests followed by COUNT ordinary binary responses.
def job(request: Request) -> IO(E.AlignJob):
  match request:
    case Bytes{m, t, k, f, qb, tb, eq}:
      IO.pure(E.AlignJob, E.AlignJob{P.byte_string(qb), P.byte_string(tb),
        E.AlignConfig{P.mode(m), P.task(t), P.threshold(k), P.pairs(eq), P.format(f)}})
    case _:
      IO.die(E.AlignJob, 2, "Expected a complete alignment request")

def read_batch(count: Nat) -> IO(List<&2, E.AlignJob>):
  match count:
    case 0n:
      IO.pure(List<&2, E.AlignJob>, Nil{})
    case 1n+p:
      do IO<List<&2, E.AlignJob>>:
        request : Request <- read_request()
        head : E.AlignJob <- job(request)
        tail : List<&2, E.AlignJob> <- read_batch(p)
        return head <> tail

def write_batch(results: List<&2, E.AlignResult>) -> IO(Unit):
  match results:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        write_response(P.encode(head))
        write_batch(tail)
