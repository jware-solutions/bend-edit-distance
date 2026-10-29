import Base
import ../EdlibTypes.bend as E

def repeat(count: Nat, +operation: E.Operation, operations: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match count:
    case 0n:
      operations
    case 1n+p:
      repeat(p, operation, operation <> operations)

def append(left: List<&2, E.Operation>, right: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match right:
    case Nil{}:
      left
    case _:
      List.reverse.go(&2, E.Operation, List.reverse(&2, E.Operation, left), right)

def transpose.from(operations: List<&2, E.Operation>, values: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match operations:
    case Nil{}:
      List.reverse(&2, E.Operation, values)
    case E.Insert{} <> tail:
      transpose.from(tail, E.Delete{} <> values)
    case E.Delete{} <> tail:
      transpose.from(tail, E.Insert{} <> values)
    case operation <> tail:
      transpose.from(tail, operation <> values)

def transpose(operations: List<&2, E.Operation>) -> List<&2, E.Operation>:
  transpose.from(operations, Nil{})
