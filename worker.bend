import Base
import ./main.bend as Main
import ./BinaryTransport.bend as BT

# Keep foreign transport effects outside the proof-checked alignment library.
# This entry point retains the legacy CLI and adds a persistent byte worker.
def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--worker" <> Nil{}:
      BT.serve(~Main.edlib_align)
    case _:
      Main.run(args)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
