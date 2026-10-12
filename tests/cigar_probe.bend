import Base
import ../EdlibTypes.bend as E
import ../lib.bend as L

# Test arbitrary paths without making traceback choose them. Both independent
# formats have the same input length and can be computed in parallel.
def read_operations(value: String) -> Maybe<&2, List<&2, E.Operation>>:
  match value:
    case SNil{}:
      Some{Nil{}}
    case SCon{'0', tail}:
      do Maybe<&2, List<&2, E.Operation>>:
        operations : List<&2, E.Operation> <- read_operations(tail)
        return E.Match{} <> operations
    case SCon{'1', tail}:
      do Maybe<&2, List<&2, E.Operation>>:
        operations : List<&2, E.Operation> <- read_operations(tail)
        return E.Insert{} <> operations
    case SCon{'2', tail}:
      do Maybe<&2, List<&2, E.Operation>>:
        operations : List<&2, E.Operation> <- read_operations(tail)
        return E.Delete{} <> operations
    case SCon{'3', tail}:
      do Maybe<&2, List<&2, E.Operation>>:
        operations : List<&2, E.Operation> <- read_operations(tail)
        return E.Mismatch{} <> operations
    case _:
      None{}

def respond(operations: Maybe<&2, List<&2, E.Operation>>) -> IO(Unit):
  match operations:
    case None{}:
      IO.die(Unit, 2, "Expected operation codes 0..3")
    case Some{+values}:
      standard extended = L.alignment_to_cigar(values, E.Standard{}) L.alignment_to_cigar(values, E.Extended{})
      IO.print("[\"" ++ standard ++ "\",\"" ++ extended ++ "\"]")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> operations <> Nil{}:
      respond(read_operations(operations))
    case _:
      IO.die(Unit, 2, "Expected OPERATIONS")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
