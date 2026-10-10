import Base
import ../Cli.bend as CLI
import ../DistanceDP.bend as DP
import ../BinaryTransport.bend as BT
import ../EdlibTypes.bend as E

def align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match config:
    case E.AlignConfig{E.NW{}, E.Distance{}, threshold, Nil{}, _}:
      +t = target
      +score = DP.distance(query, t)
      E.distance_result(score, E.end_coordinate(String.length(t)),
        E.within_threshold(threshold, score))
    case _:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}

# Separate executable so differential tests exercise DP without Myers dispatch.
def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      BT.serve(~align)
    case _:
      CLI.run(~DP.distance, args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
