import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ./PreparedBytes.bend as Bytes
import ./ByteTarget.bend as BT
import ./PreparedTransport.bend as P
import ./Transport.bend as T
import ./Myers.bend as M
import ./Batch.bend as B
import ./Word.bend as Word

# Optional BED2 operations 6/7 consume owned target buffers. Their contract is
# unlimited NW DISTANCE; existing requests keep their original representation.
def single(~State: Type, ~run: State -> BT.Target -> (State & E.AlignResult),
               +handle: U32, target: BT.Target, exists: Bool) -> IO(Unit):
  match exists:
    case False{}:
      P.error()
    case True{}:
      do IO<Unit>:
        state : State <- P.take(State, handle)
        P.aligned(~State, handle, run(state, target))

def batch.aligned(~State: Type, +handle: U32, value: State & List<&2, E.AlignResult>) -> IO(Unit):
  (state, +results) = value
  do IO<Unit>:
    P.restore(State, handle, state)
    P.control(7, 0, handle, U32.from_nat(List.length(&2, E.AlignResult, results)))
    T.write_batch(results)

def batch(~State: Type, ~run: State -> BT.Batch -> (State & List<&2, E.AlignResult>),
              +handle: U32, values: BT.Batch, exists: Bool) -> IO(Unit):
  match exists:
    case False{}:
      P.control(7, 1, handle, 0)
    case True{}:
      do IO<Unit>:
        state : State <- P.take(State, handle)
        batch.aligned(~State, handle, run(state, values))

def respond(~State: Type,
                ~make: String -> List<&2, E.EqualityPair> -> State,
                ~size: State -> (State & Nat),
                ~single_string: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
                ~many_string: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
                ~single_bytes: State -> BT.Target -> (State & E.AlignResult),
                ~many_bytes: State -> BT.Batch -> (State & List<&2, E.AlignResult>),
                request: T.Request) -> IO(Unit):
  match request:
    case T.CapabilitiesRequest{}:
      P.control(8, 0, Word.width_u32(), U32.from_nat(Bytes.maximum_query()))
    case T.OwnedPreparedRequest{+handle, target}:
      do IO<Unit>:
        exists : Bool <- P.has(handle)
        single(~State, ~single_bytes, handle, target, exists)
    case T.OwnedPreparedBatchRequest{+handle, values}:
      do IO<Unit>:
        exists : Bool <- P.has(handle)
        batch(~State, ~many_bytes, handle, values, exists)
    case _:
      P.respond(~State, ~make, ~size, ~single_string, ~many_string, ~M.edlib_align, ~B.align_batch, request)

def run(~State: Type,
            ~make: String -> List<&2, E.EqualityPair> -> State,
            ~size: State -> (State & Nat),
            ~single_string: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
            ~many_string: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
            ~single_bytes: State -> BT.Target -> (State & E.AlignResult),
            ~many_bytes: State -> BT.Batch -> (State & List<&2, E.AlignResult>),
            fuel: Nat, request: T.Request) -> IO(Unit):
  match fuel request:
    case _ T.End{}:
      P.clear()
    case 0n _:
      P.clear()
    case 1n+p _:
      do IO<Unit>:
        respond(~State, ~make, ~size, ~single_string, ~many_string, ~single_bytes, ~many_bytes, request)
        next : T.Request <- T.read_owned_request()
        run(~State, ~make, ~size, ~single_string, ~many_string, ~single_bytes, ~many_bytes, p, next)

def serve_generic(~State: Type,
                      ~make: String -> List<&2, E.EqualityPair> -> State,
                      ~size: State -> (State & Nat),
                      ~single_string: State -> T.SizedTarget -> Q.Options -> (State & E.AlignResult),
                      ~many_string: State -> List<&2, T.SizedTarget> -> Q.Options -> (State & List<&2, E.AlignResult>),
                      ~single_bytes: State -> BT.Target -> (State & E.AlignResult),
                      ~many_bytes: State -> BT.Batch -> (State & List<&2, E.AlignResult>)) -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_owned_request()
    run(~State, ~make, ~size, ~single_string, ~many_string, ~single_bytes, ~many_bytes, 4294967295n, request)

def serve() -> IO(Unit):
  serve_generic(~Q.Prepared, ~P.cpu_prepare, ~Q.retained_bytes, ~P.cpu_align, ~P.cpu_many, ~Bytes.align, ~Bytes.many)
