import Base
import ../EdlibTypes.bend as E
import ./ByteProtocol.bend as P
import ./ByteTarget.bend as Own

# The native bridge constructs one Char per raw byte, without UTF-8 decoding.
type SizedTarget is Data:
  SizedTarget{sequence: String, length: Nat}

type Request is Type:
  End{}
  Invalid{}
  Bytes{mode: U32, task: U32, threshold: U32, format: U32,
    query: String, target: String, equalities: List<U32>}
  PrepareRequest{query: String, equalities: List<U32>}
  PreparedRequest{handle: U32, mode: U32, task: U32, threshold: U32, format: U32, target: SizedTarget}
  ReleaseRequest{handle: U32}
  BatchRequest{count: U32}
  PreparedBatchRequest{handle: U32, mode: U32, task: U32, threshold: U32, format: U32, targets: List<&2, SizedTarget>}
  InvalidControl{operation: U32}
  OwnedPreparedRequest{handle: U32, target: Own.Target}
  OwnedPreparedBatchRequest{handle: U32, batch: Own.Batch}
  CapabilitiesRequest{}

def read_request() -> IO(Request):
  import "./transport.c"

# A typed empty prototype lets the pinned FFI pass its constructor identity
# without coupling C to generated, cross-module identifier names.
def read_owned_request_native(prototype: Own.Target) -> IO(Request):
  import "./transport.c"

def read_owned_request() -> IO(Request):
  read_owned_request_native(Own.Target{[0 : U32*1n], 0n})

def write_response(bytes: List<U32>) -> IO(Unit):
  import "./transport.c"

def write_result_fields(status: U32, distance: U32, ends: List<U32>,
                          starts: Maybe<&1, List<U32>>,
                          operations: Maybe<&1, List<U32>>, cigar: Maybe<&2, String>) -> IO(Unit):
  import "./transport.c"

def write_result(result: E.AlignResult) -> IO(Unit):
  E.AlignResult{status, distance, ends, starts, operations, cigar} = result
  write_result_fields(P.status_value(status), P.distance_value(distance), P.coordinate_values(ends),
    P.optional_coordinates(starts), P.optional_operations(operations), cigar)

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
      do IO<Bool>:
        write_result(align(qb, tb,
          E.AlignConfig{P.mode(m), P.task(t), P.threshold(k), P.pairs(eq), P.format(f)}))
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
      IO.pure(E.AlignJob, E.AlignJob{qb, tb,
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

def write_batch_items(results: List<&2, E.AlignResult>) -> IO(Unit):
  match results:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        write_result(head)
        write_batch_items(tail)

# Standard I/O keeps a bounded buffer; flush before accepting another request.
def begin_batch_output() -> IO(Unit):
  import "./transport.c"

def end_batch_output() -> IO(Unit):
  import "./transport.c"

def write_batch(results: List<&2, E.AlignResult>) -> IO(Unit):
  do IO<Unit>:
    begin_batch_output()
    write_batch_items(results)
    end_batch_output()
