import Base
import ./src/Myers.bend as M
import ./src/Cli.bend as CLI
import ./src/PreparedTransport.bend as T
import ./src/PoolTransport.bend as Pool

# Keep foreign transport effects outside the proof-checked alignment library.
# This entry point retains the legacy CLI and adds a persistent byte worker.
def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      T.serve()
    case _ <> "--worker" <> "--shards" <> shards <> Nil{}:
      Pool.serve(shards)
    case _:
      CLI.run(~M.distance, ~M.edlib_align, args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
