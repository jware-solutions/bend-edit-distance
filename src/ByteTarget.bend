import Base

# Four little-endian bytes occupy each U32 cell. Logical byte lengths guard
# the single owner; extracting a byte always produces a value in 0..255.
type Target is Type:
  Target{bytes: Array<U32>, length: Nat}

type Batch is Type:
  Batch{targets: List<&1, Target>, count: Nat, units: Nat, uniform: U32}

type Checked is Type:
  Checked{target: Target, valid: Bool}

def cell_bytes() -> Nat:
  4n

def log_cell_bytes() -> Nat:
  2n

def fits(+length: Nat, capacity: U32) -> Bool:
  Bool.and(Nat.is_le(length, 2147483647n), Nat.is_le(length, Nat.mul(U32.to_nat(capacity), cell_bytes())))

def checked.size(+length: Nat, value: Array<U32> & U32) -> Checked:
  (bytes, capacity) = value
  Checked{Target{bytes, length}, fits(length, capacity)}

def checked(target: Target) -> Checked:
  Target{bytes, length} = target
  checked.size(length, Array.size(U32, bytes))

type Reversed is Type:
  Reversed{bytes: Array<U32>, string: String}

def byte(word: U32, index: U32) -> U32:
  U32.and(U32.shrn(word, U32.to_nat(U32.shln(U32.and(index, 3), 3n))), 255)

def string.read(string: String, index: U32, value: Array<U32> & U32) -> Reversed:
  (bytes, code) = value
  Reversed{bytes, SCon{Chr{byte(code, index)}, string}}

# The caller checks logical length before this backwards traversal.
def string.scan(fuel: Nat, +index: U32, state: Reversed) -> String:
  match fuel state:
    case 0n Reversed{_, string}:
      string
    case 1n+p Reversed{bytes, string}:
      string.scan(p, U32.sub(index, 1), string.read(string, U32.sub(index, 1), bytes[U32.shrn(U32.sub(index, 1), log_cell_bytes())]))

def string(target: Target) -> String:
  Target{bytes, +length} = target
  string.scan(length, U32.from_nat(length), Reversed{bytes, ""})
