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
