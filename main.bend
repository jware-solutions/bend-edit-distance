import Base
import ./src/Myers.bend as M
import ./src/Cli.bend as CLI

# Compatible console entry point; the public library imports Myers directly.
def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    CLI.run(~M.distance, ~M.edlib_align, args)
