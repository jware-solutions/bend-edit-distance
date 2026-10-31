import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ./Myers.bend as M
import ./Batch.bend as B
import ./Transport.bend as T
import ./ByteProtocol.bend as P

def retain(-A: Type, value: A, bytes: U32) -> IO(U32):
  import "./prepared_cache.c"

def has(handle: U32) -> IO(Bool):
  import "./prepared_cache.c"

def take(-A: Type, handle: U32) -> IO(A):
  import "./prepared_cache.c"

def restore(-A: Type, handle: U32, value: A) -> IO(Unit):
  import "./prepared_cache.c"

def release(handle: U32) -> IO(Bool):
  import "./prepared_cache.c"

def cache_bytes() -> IO(U32):
  import "./prepared_cache.c"

def clear() -> IO(Unit):
  import "./prepared_cache.c"

def control(+operation: U32, status: U32, handle: U32, count: U32) -> IO(Unit):
  do IO<Unit>:
    bytes : U32 <- cache_bytes()
    T.write_response(P.join([[66, 69, 82, 50], P.u32_bytes(operation), P.u32_bytes(status),
      P.u32_bytes(handle), P.u32_bytes(bytes), P.u32_bytes(count)]))

def error() -> IO(Unit):
  T.write_response(P.encode(E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}))

def prepared.saved(handle: U32, saved: Bool) -> IO(Unit):
  match saved:
    case True{}:
      control(1, 0, handle, 1)
    case False{}:
      control(1, 1, 0, 0)

def prepared.handle(+handle: U32) -> IO(Unit):
  prepared.saved(handle, U32.is_ne(handle, 0))

def prepared(~State: Type, result: State & Nat) -> IO(Unit):
  (query, bytes) = result
  do IO<Unit>:
    handle : U32 <- retain(State, query, U32.from_nat(Nat.add(4096n, Nat.mul(bytes, 2n))))
    prepared.handle(handle)

def aligned(~State: Type, handle: U32, result: State & E.AlignResult) -> IO(Unit):
  (query, value) = result
  do IO<Unit>:
    restore(State, handle, query)
    T.write_result(value)

def align(~State: Type, ~run: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
          +handle: U32, target: T.SizedTarget, options: Q.Options, exists: Bool) -> IO(Unit):
  match exists:
    case False{}:
      error()
    case True{}:
      do IO<Unit>:
        query : State <- take(State, handle)
        aligned(~State, handle, run(query, target, options))

def batch_aligned(~State: Type, +handle: U32, result: State & List<&2, E.AlignResult>) -> IO(Unit):
  (query, +values) = result
  do IO<Unit>:
    restore(State, handle, query)
    control(5, 0, handle, U32.from_nat(List.length(&2, E.AlignResult, values)))
    T.write_batch(values)

def batch(~State: Type, ~run: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
          +handle: U32, values: List<&2, T.SizedTarget>, options: Q.Options, exists: Bool) -> IO(Unit):
  match exists:
    case False{}:
      control(5, 1, handle, 0)
    case True{}:
      do IO<Unit>:
        query : State <- take(State, handle)
        batch_aligned(~State, handle, run(query, values, options))

def released(handle: U32, removed: Bool) -> IO(Unit):
  control(3, Bool.to_u32(Bool.not(removed)), handle, 0)

def invalid(operation: U32) -> IO(Unit):
  match operation:
    case 2:
      error()
    case _:
      control(operation, 1, 0, 0)

def respond(~State: Type,
            ~make: String -> List<&2, E.EqualityPair> -> State,
            ~size: State -> (State & Nat),
            ~single: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
            ~many: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
            ~ordinary_single: String -> String -> E.AlignConfig -> E.AlignResult,
            ~ordinary: List<&2, E.AlignJob> -> List<&2, E.AlignResult>,
            request: T.Request) -> IO(Unit):
  match request:
    case T.PrepareRequest{query, pairs}:
      prepared(~State, size(make(query, P.pairs(pairs))))
    case T.PreparedRequest{+handle, m, t, k, f, target}:
      do IO<Unit>:
        exists : Bool <- has(handle)
        align(~State, ~single, handle, target, Q.Options{P.mode(m), P.task(t), P.threshold(k), P.format(f)}, exists)
    case T.ReleaseRequest{+handle}:
      do IO<Unit>:
        removed : Bool <- release(handle)
        released(handle, removed)
    case T.BatchRequest{+count}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- T.read_batch(U32.to_nat(count))
        +values : List<&2, E.AlignResult> = ordinary(jobs)
        control(4, 0, 0, count)
        T.write_batch(values)
    case T.PreparedBatchRequest{+handle, m, t, k, f, values}:
      do IO<Unit>:
        exists : Bool <- has(handle)
        batch(~State, ~many, handle, values, Q.Options{P.mode(m), P.task(t), P.threshold(k), P.format(f)}, exists)
    case T.InvalidControl{operation}:
      invalid(operation)
    case T.OwnedPreparedRequest{_, _}:
      invalid(6)
    case T.OwnedPreparedBatchRequest{_, _}:
      invalid(7)
    case T.CapabilitiesRequest{}:
      invalid(8)
    case _:
      do IO<Unit>:
        alive : Bool <- T.respond(~ordinary_single, request)
        return Unit{}

def run(~State: Type,
        ~make: String -> List<&2, E.EqualityPair> -> State,
        ~size: State -> (State & Nat),
        ~single: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
        ~many: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
        ~ordinary_single: String -> String -> E.AlignConfig -> E.AlignResult,
        ~ordinary: List<&2, E.AlignJob> -> List<&2, E.AlignResult>,
        fuel: Nat, request: T.Request) -> IO(Unit):
  match fuel request:
    case _ T.End{}:
      clear()
    case 0n _:
      clear()
    case 1n+p _:
      do IO<Unit>:
        respond(~State, ~make, ~size, ~single, ~many, ~ordinary_single, ~ordinary, request)
        next : T.Request <- T.read_request()
        run(~State, ~make, ~size, ~single, ~many, ~ordinary_single, ~ordinary, p, next)

def serve_generic(~State: Type,
                  ~make: String -> List<&2, E.EqualityPair> -> State,
                  ~size: State -> (State & Nat),
                  ~single: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
                  ~many: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
                  ~ordinary_single: String -> String -> E.AlignConfig -> E.AlignResult,
                  ~ordinary: List<&2, E.AlignJob> -> List<&2, E.AlignResult>) -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    run(~State, ~make, ~size, ~single, ~many, ~ordinary_single, ~ordinary, 4294967295n, request)

def cpu_prepare(query: String, pairs: List<&2, E.EqualityPair>) -> Q.Prepared:
  Q.prepare(query, pairs)

def cpu_align(query: Q.Prepared, target: T.SizedTarget, options: Q.Options) -> Q.Prepared & E.AlignResult:
  T.SizedTarget{sequence, length} = target
  Q.align_sized_known(query, sequence, options, length, True{})

# Framing supplies exact byte counts; no String length or byte-domain scan is needed.
def cpu_batch(values: List<&2, T.SizedTarget>, +options: Q.Options, state: Q.BatchState) -> Q.Prepared & List<&2, E.AlignResult>:
  match values state:
    case Nil{} Q.BatchState{query, results}:
      (query, List.reverse(&2, E.AlignResult, results))
    case target <> tail Q.BatchState{query, results}:
      cpu_batch(tail, options, Q.batch.updated(results, cpu_align(query, target, options)))

def cpu_many(query: Q.Prepared, values: List<&2, T.SizedTarget>, options: Q.Options) -> Q.Prepared & List<&2, E.AlignResult>:
  cpu_batch(values, options, Q.BatchState{query, Nil{}})

def serve() -> IO(Unit):
  serve_generic(~Q.Prepared, ~cpu_prepare, ~Q.retained_bytes, ~cpu_align, ~cpu_many,
    ~M.edlib_align, ~B.align_batch)
