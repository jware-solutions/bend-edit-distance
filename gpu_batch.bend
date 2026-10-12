import Base
import ./GpuBatch.bend as G
import ./BatchIO.bend as BT
import ./EdlibTypes.bend as E

def parsed(count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural batch count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read(n)
        BT.write(G.align_batch(jobs))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> count <> Nil{}:
      parsed(Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected COUNT and COUNT binary requests on stdin")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
