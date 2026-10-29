import Base
import ../EdlibTypes.bend as E
import ../src/Transport.bend as T

def echo(target: T.SizedTarget) -> E.AlignResult:
  T.SizedTarget{sequence, +length} = target
  E.AlignResult{E.Ok{}, E.Found{length}, [E.end_coordinate(length)], None{}, None{}, Some{sequence}}

def echoes(values: List<&2, T.SizedTarget>) -> List<&2, E.AlignResult>:
  match values:
    case Nil{}:
      Nil{}
    case target <> tail:
      echo(target) <> echoes(tail)

def respond(request: T.Request) -> IO(Unit):
  match request:
    case T.PreparedRequest{_, _, _, _, _, target}:
      T.write_result(echo(target))
    case T.PreparedBatchRequest{_, _, _, _, _, targets}:
      T.write_batch(echoes(targets))
    case _:
      IO.die(Unit, 2, "Expected a prepared target request")

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    respond(request)
