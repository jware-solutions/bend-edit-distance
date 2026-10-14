import Base

# Base.String.length builds one continuation per character on Bend 2.0.36's
# device stack (2048 words). An accumulator keeps this traversal flat, so
# supported 4096-byte inputs do not exhaust a lane before Myers starts.
def length_from(sequence: String, count: Nat) -> Nat:
  match sequence:
    case SNil{}:
      count
    case SCon{_, tail}:
      length_from(tail, 1n+count)

def length(sequence: String) -> Nat:
  length_from(sequence, 0n)
