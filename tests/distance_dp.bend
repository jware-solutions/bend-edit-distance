import Base
import ../src/Cli.bend as CLI
import ../src/DistanceDP.bend as DP
import ../src/Transport.bend as BT

# Separate executable so differential tests exercise DP without Myers dispatch.
def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      BT.serve(~DP.align)
    case _:
      CLI.run_distance(~DP.distance, args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
