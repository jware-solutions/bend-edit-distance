import Base
import ../EdlibTypes.bend as E
import ../src/Frontier.bend as F
import ../src/Transport.bend as T

def show(values: List<U32>) -> String:
  match values:
    case Nil{}:
      ""
    case value <> Nil{}:
      U32.show(value)
    case value <> tail:
      U32.show(value) ++ "," ++ show(tail)

def run(job: E.AlignJob) -> IO(Unit):
  E.AlignJob{query, target, E.AlignConfig{_, _, _, pairs, _}} = job
  IO.print(show(F.row(query, target, pairs)))

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    run(job)
