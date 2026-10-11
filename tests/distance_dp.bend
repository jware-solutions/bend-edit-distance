import Base
import ../Cli.bend as CLI
import ../DistanceDP.bend as DP
import ../BinaryTransport.bend as BT

# Separate executable so differential tests exercise DP without Myers dispatch.
def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      BT.serve(~DP.align)
    case _:
      CLI.run(~DP.distance, args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
