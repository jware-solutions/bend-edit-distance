import Base
import ../EdlibTypes.bend as E
import ../src/Frontier.bend as F
import ../src/Reconstruction.bend as R
import ../src/Sequence.bend as S
import ../src/Transport.bend as T

def show(values: List<U32>) -> String:
  match values:
    case Nil{}:
      ""
    case value <> Nil{}:
      U32.show(value)
    case value <> tail:
      U32.show(value) ++ "," ++ show(tail)

def select(args: List<String>, +query: String, +target: String, pairs: List<&2, E.EqualityPair>) -> IO(Unit):
  match args:
    case _ <> "midpoint" <> Nil{}:
      +half = Nat.div(String.length(query), 2n)
      IO.print(Nat.show(R.midpoint(S.take(query, half), String.drop(query, half), target, pairs)))
    case _:
      IO.print(show(F.row(query, target, pairs)))

def run(args: List<String>, job: E.AlignJob) -> IO(Unit):
  E.AlignJob{query, target, E.AlignConfig{_, _, _, pairs, _}} = job
  select(args, query, target, pairs)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    run(args, job)
