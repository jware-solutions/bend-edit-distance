import Base

# An accumulator keeps length traversal flat, without a continuation per byte.
def length_from(sequence: String, count: Nat) -> Nat:
  match sequence:
    case SNil{}:
      count
    case SCon{_, tail}:
      length_from(tail, 1n+count)

def length(sequence: String) -> Nat:
  length_from(sequence, 0n)

def take.from(sequence: String, count: Nat, values: String) -> String:
  match sequence count:
    case SNil{} _:
      String.reverse(values)
    case SCon{_, _} 0n:
      String.reverse(values)
    case SCon{head, tail} 1n+p:
      take.from(tail, p, SCon{head, values})

def take(sequence: String, count: Nat) -> String:
  take.from(sequence, count, "")
