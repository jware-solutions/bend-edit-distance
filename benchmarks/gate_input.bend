import Base
import ../EdlibTypes.bend as E
import ../src/Transport.bend as BT

# An empty native batch still needs a round trigger. Consume one dummy BED1
# frame outside timing so the probe cannot precompute empty rounds at startup.
def read(count: Nat) -> IO(List<&2, E.AlignJob>):
  match count:
    case 0n:
      do IO<List<&2, E.AlignJob>>:
        ignored : List<&2, E.AlignJob> <- BT.read_batch(1n)
        return Nil{}
    case 1n+p:
      BT.read_batch(1n+p)

def targets(jobs: List<&2, E.AlignJob>) -> List<&2, String>:
  match jobs:
    case Nil{}:
      Nil{}
    case E.AlignJob{_, target, _} <> tail:
      target <> targets(tail)

def read_targets(count: Nat) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    jobs : List<&2, E.AlignJob> <- read(count)
    return targets(jobs)
