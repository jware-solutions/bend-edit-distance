import ../src/Batch.bend as B
import Base
import ../lib.bend as L
import ../EdlibTypes.bend as E
import ../src/Transport.bend as BT

def indexed(jobs: List<&2, E.AlignJob>, +index: Nat, +holes: Bool) -> List<&2, B.IndexedResult>:
  match jobs:
    case Nil{}:
      Nil{}
    case job <> tail:
      B.single(Bool.pick(Nat, holes, Nat.add(index, 257n), Nat.mod(index, 17n)), job) <>
        indexed(tail, 1n+index, holes)

def compute(mode: String, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match mode:
    case "batch":
      BT.write_batch(L.align_batch(jobs))
    case "gather-duplicates":
      BT.write_batch(B.ordered(indexed(jobs, 0n, False{})))
    case "sort-duplicates":
      BT.write_batch(B.results(List.sort(~B.IndexedResult, ~B.earlier, indexed(jobs, 0n, False{}))))
    case "gather-holes":
      BT.write_batch(B.ordered(indexed(jobs, 0n, True{})))
    case "sort-holes":
      BT.write_batch(B.results(List.sort(~B.IndexedResult, ~B.earlier, indexed(jobs, 0n, True{}))))
    case _:
      IO.die(Unit, 2, "Expected batch or ordering probe")

def parsed(mode: String, count: Maybe<&2, Nat>) -> IO(Unit):
  match count:
    case None{}:
      IO.die(Unit, 2, "Expected a natural count")
    case Some{n}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(n)
        compute(mode, jobs)

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> mode <> count <> Nil{}:
      parsed(mode, Nat.read(count))
    case _:
      IO.die(Unit, 2, "Expected MODE COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
