import Base

# Replace this module together with the word-typed profile/workspace storage
# when the pinned compiler supports U64. Endpoint conventions live elsewhere.
def width() -> Nat:
  32n

def width_u32() -> U32:
  32

def log_width() -> Nat:
  5n

def top_shift() -> Nat:
  31n

def all_bits() -> U32:
  4294967295

def band_margin() -> Nat:
  63n

def expansion_margin() -> Nat:
  62n

def blocks(length: Nat) -> Nat:
  Nat.div(Nat.add(length, top_shift()), width())

def bottom(index: U32) -> U32:
  U32.shln(index, log_width())

def padding(+length: Nat) -> Nat:
  Nat.sub(Nat.mul(blocks(length), width()), length)

def used(length: Nat) -> Nat:
  Nat.mod(length, width())

def top(bits: U32) -> U32:
  U32.shrn(bits, top_shift())

def supports_u64() -> Bool:
  False{}

def supports_native_library() -> Bool:
  False{}

def literal_bit(position: U32) -> U32:
  U32.shln(1, U32.to_nat(U32.and(position, U32.sub(width_u32(), 1))))

def high_padding(used: U32) -> U32:
  U32.not(U32.sub(U32.shln(1, U32.to_nat(used)), 1))

# SWAR population count keeps padded-cell decoding independent of padding size.
# Arithmetic wraps at U32, including the final byte-sum multiplication.
def count_ones(+bits: U32) -> U32:
  +a = U32.sub(bits, U32.and(U32.shr(bits), 1431655765))
  +b = U32.add(U32.and(a, 858993459), U32.and(U32.shrn(a, 2n), 858993459))
  c = U32.and(U32.add(b, U32.shrn(b, 4n)), 252645135)
  U32.shrn(U32.mul(c, 16843009), 24n)

def decode(padding: Nat, pv: U32, mv: U32, score: U32) -> U32:
  match padding:
    case 0n:
      score
    case 1n+p:
      +shift = Nat.sub(top_shift(), p)
      U32.add(U32.sub(score, count_ones(U32.shrn(pv, shift))), count_ones(U32.shrn(mv, shift)))
