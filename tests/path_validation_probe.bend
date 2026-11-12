import Base
import ../EdlibTypes.bend as E
import ../src/Alignment.bend as A
import ../src/Transport.bend as T

# Test-only operation/interval injection into the real fail-closed boundary.
def operations(codes: String) -> List<&2, E.Operation>:
  match codes:
    case SNil{}:
      Nil{}
    case SCon{'0', tail}:
      E.Match{} <> operations(tail)
    case SCon{'1', tail}:
      E.Insert{} <> operations(tail)
    case SCon{'2', tail}:
      E.Delete{} <> operations(tail)
    case SCon{_, tail}:
      E.Mismatch{} <> operations(tail)

def validate(+location: A.Location, +ops: List<&2, E.Operation>, query: String,
             +target: String, config: E.AlignConfig) -> E.AlignResult:
  match config:
    case E.AlignConfig{_, _, E.MaxDistance{score}, pairs, format}:
      A.path_validate(query, A.span(target, location), pairs, U32.from_nat(score),
        [location], format, ops, A.location_valid(target, location))
    case _:
      E.not_found()

def job(+location: A.Location, +ops: List<&2, E.Operation>, value: E.AlignJob) -> IO(Unit):
  E.AlignJob{q, t, config} = value
  T.write_result(validate(location, ops, q, t, config))

def rounds(fuel: Nat, +location: A.Location, +ops: List<&2, E.Operation>, request: T.Request) -> IO(Unit):
  match fuel request:
    case 0n _:
      IO.pure(Unit, Unit{})
    case _ T.End{}:
      IO.pure(Unit, Unit{})
    case 1n+p _:
      do IO<Unit>:
        value : E.AlignJob <- T.job(request)
        job(location, ops, value)
        next : T.Request <- T.read_request()
        rounds(p, location, ops, next)

def serve(+location: A.Location, +ops: List<&2, E.Operation>) -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    rounds(4294967295n, location, ops, request)

def indexed(codes: String, start: Nat, end: Maybe<&2, Nat>) -> IO(Unit):
  match end:
    case Some{e}:
      serve(A.Location{E.Position{e}, start}, operations(codes))
    case _:
      IO.die(Unit, 2, "Invalid endpoint")

def parsed(codes: String, start: Maybe<&2, Nat>, end: String) -> IO(Unit):
  match start end:
    case Some{s} "-1":
      serve(A.Location{E.BeforeStart{}, s}, operations(codes))
    case Some{s} _:
      indexed(codes, s, Nat.read(end))
    case _ _:
      IO.die(Unit, 2, "Invalid interval")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> codes <> start <> end <> "--worker" <> Nil{}:
      parsed(codes, Nat.read(start), end)
    case _:
      IO.die(Unit, 2, "Expected CODES START END --worker")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
