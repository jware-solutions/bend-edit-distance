import Base
import ../EdlibTypes.bend as E
import ./BitVector.bend as V

# Symbol-major masks with a byte lookup. UINT32_MAX denotes a missing row.
# Stride is a power of two >= blocks. Accesses guard logical bounds because
# Bend arrays wrap indexes. Each profile has exactly one owner.
type Profile is Type:
  Profile{lookup: Array<U32>, masks: Array<U32>, stride: U32, rows: U32, blocks: U32, used: U32}

def depth(+size: Nat) -> Nat:
  Nat.add(Bool.pick(Nat, Nat.is_gt(size, 1n), 1n, 0n),
    U32.log2(U32.from_nat(Nat.max(1n, Nat.sub(size, 1n)))))

def byte_pairs(pairs: List<&2, E.EqualityPair>) -> Bool:
  match pairs:
    case Nil{}:
      True{}
    case E.EqualityPair{a, b} <> tail:
      Bool.and(Bool.and(U32.is_lt(Char.to_u32(a), 256), U32.is_lt(Char.to_u32(b), 256)), byte_pairs(tail))

def bytes_from(query: String, valid: Bool) -> Bool:
  match query valid:
    case SNil{} _:
      valid
    case _ False{}:
      False{}
    case SCon{h, t} True{}:
      bytes_from(t, U32.is_lt(Char.to_u32(h), 256))

def bytes(query: String) -> Bool:
  bytes_from(query, True{})

def add_symbol(lookup: Array<U32>, +code: U32, +rows: U32, missing: Bool) -> Array<U32> & U32:
  match missing:
    case True{}:
      (lookup[code] <- rows, U32.inc(rows))
    case False{}:
      (lookup, rows)

def symbol.result(+code: U32, rows: U32, result: Array<U32> & U32) -> Array<U32> & U32:
  (lookup, row) = result
  add_symbol(lookup, code, rows, U32.is_eq(row, 4294967295))

def symbol(lookup: Array<U32>, +code: U32, rows: U32) -> Array<U32> & U32:
  symbol.result(code, rows, lookup[code])

def alphabet(query: String, state: Array<U32> & U32) -> Array<U32> & U32:
  match query state:
    case SNil{} _:
      state
    case SCon{h, t} _:
      (lookup, rows) = state
      alphabet(t, symbol(lookup, Char.to_u32(h), rows))

def edge.result(+a: U32, b: U32, result: Array<List<&2, U32>> & List<&2, U32>) -> Array<List<&2, U32>>:
  (adjacent, neighbors) = result
  Array.set(List<&2, U32>, adjacent, a, b <> neighbors)

def edge(adjacent: Array<List<&2, U32>>, +a: U32, b: U32) -> Array<List<&2, U32>>:
  edge.result(a, b, Array.get(List<&2, U32>, adjacent, a))

def symbols.second(b: U32, result: Array<U32> & U32) -> Array<U32> & U32:
  (lookup, rows) = result
  symbol(lookup, b, rows)

def equalities(pairs: List<&2, E.EqualityPair>, state: Array<U32> & U32,
                 adjacent: Array<List<&2, U32>>) -> (Array<U32> & U32) & Array<List<&2, U32>>:
  match pairs state:
    case Nil{} _:
      (state, adjacent)
    case E.EqualityPair{a, b} <> tail _:
      (lookup, rows) = state
      +ac = Char.to_u32(a)
      +bc = Char.to_u32(b)
      equalities(tail, symbols.second(bc, symbol(lookup, ac, rows)), edge(edge(adjacent, ac, bc), bc, ac))

def set_bit.previous(lookup: Array<U32>, +index: U32, bit: U32,
                       result: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (masks, previous) = result
  (lookup, masks[index] <- U32.or(previous, bit))

def set_bit.row(masks: Array<U32>, stride: U32, block: U32, bit: U32,
                  result: Array<U32> & U32) -> Array<U32> & Array<U32>:
  (lookup, row) = result
  +index = U32.add(U32.mul(row, stride), block)
  set_bit.previous(lookup, index, bit, masks[index])

def set_bit(lookup: Array<U32>, masks: Array<U32>, code: U32,
              stride: U32, block: U32, bit: U32) -> Array<U32> & Array<U32>:
  set_bit.row(masks, stride, block, bit, lookup[code])

def set_neighbors(neighbors: List<&2, U32>, state: Array<U32> & Array<U32>,
                    +stride: U32, +block: U32, +bit: U32) -> Array<U32> & Array<U32>:
  match neighbors state:
    case Nil{} _:
      state
    case code <> tail _:
      (lookup, masks) = state
      set_neighbors(tail, set_bit(lookup, masks, code, stride, block, bit), stride, block, bit)

def fill.neighbors(state: Array<U32> & Array<U32>, stride: U32, +position: U32,
                     result: Array<List<&2, U32>> & List<&2, U32>) ->
                     (Array<U32> & Array<U32>) & Array<List<&2, U32>>:
  (adjacent, neighbors) = result
  (set_neighbors(neighbors, state, stride, U32.shrn(position, 5n),
    U32.shln(1, U32.to_nat(U32.and(position, 31)))), adjacent)

def fill.next(+stride: U32, +position: U32, +code: U32,
                state: Array<U32> & Array<U32>, adjacent: Array<List<&2, U32>>) ->
                (Array<U32> & Array<U32>) & Array<List<&2, U32>>:
  (lookup, masks) = state
  fill.neighbors(set_bit(lookup, masks, code, stride, U32.shrn(position, 5n),
    U32.shln(1, U32.to_nat(U32.and(position, 31)))), stride, position,
    Array.get(List<&2, U32>, adjacent, code))

# Query positions contribute their literal and direct neighbors only; expanded
# masks are never used as sources for another equality edge.
def fill(query: String, state: (Array<U32> & Array<U32>) & Array<List<&2, U32>>,
           +stride: U32, +position: U32) -> (Array<U32> & Array<U32>) & Array<List<&2, U32>>:
  match query state:
    case SNil{} _:
      state
    case SCon{h, t} _:
      (masks, adjacent) = state
      fill(t, fill.next(stride, position, Char.to_u32(h), masks, adjacent), stride, U32.inc(position))

def build.filled(stride: U32, rows: U32, blocks: U32, used: U32,
                   result: (Array<U32> & Array<U32>) & Array<List<&2, U32>>) -> Profile:
  (state, adjacent) = result
  (lookup, masks) = state
  Profile{lookup, masks, stride, rows, blocks, used}

def build.equalities(query: String, +length: Nat,
                       result: (Array<U32> & U32) & Array<List<&2, U32>>) -> Profile:
  (state, adjacent) = result
  (lookup, rows0) = state
  +rows = {rows0 : U32}
  +blocks = V.ceil_div(length, 32n)
  +stride_depth = depth(blocks)
  +stride = U32.shln(1, stride_depth)
  masks = Array.new(U32, Nat.add(stride_depth, depth(U32.to_nat(rows))), 0)
  build.filled(stride, rows, U32.from_nat(blocks), U32.from_nat(Nat.mod(length, 32n)),
    fill(query, (({lookup : Array<U32>}, {masks : Array<U32>}), adjacent), stride, 0))

def build(+query: String, length: Nat, pairs: List<&2, E.EqualityPair>) -> Profile:
  build.equalities(query, length,
    equalities(pairs, alphabet(query, ([4294967295 : U32*256n], 0)), [Nil{} : List<&2, U32>*256n]))

def row.result(masks: Array<U32>, stride: U32, rows: U32, blocks: U32, used: U32,
                  result: Array<U32> & U32) -> Profile & U32:
  (lookup, index) = result
  (Profile{lookup, masks, stride, rows, blocks, used}, index)

# Preserve the old eight-bit target lookup outside the byte specialization.
def row(profile: Profile, code: U32) -> Profile & U32:
  Profile{lookup, masks, stride, rows, blocks, used} = profile
  row.result(masks, stride, rows, blocks, used, lookup[U32.and(code, 255)])

def mask_at(masks: Array<U32>, index: U32, valid: Bool) -> Array<U32> & U32:
  match valid:
    case True{}:
      masks[index]
    case False{}:
      (masks, 0)

def padding_mask(+used: U32, last: Bool) -> U32:
  Bool.pick(U32, Bool.and(last, U32.is_ne(used, 0)),
    U32.not(U32.sub(U32.shln(1, U32.to_nat(used)), 1)), 0)

def mask.result(lookup: Array<U32>, stride: U32, rows: U32, +blocks: U32, +used: U32,
                   block: U32, result: Array<U32> & U32) -> Profile & U32:
  (masks, bits) = result
  (Profile{lookup, masks, stride, rows, blocks, used},
    U32.or(bits, padding_mask(used, U32.is_eq(U32.inc(block), blocks))))

def mask(profile: Profile, +row: U32, +block: U32) -> Profile & U32:
  Profile{lookup, masks, +stride, +rows, +blocks, +used} = profile
  mask.result(lookup, stride, rows, blocks, used, block,
    mask_at(masks, U32.add(U32.mul(row, stride), block),
      Bool.and(U32.is_lt(row, rows), U32.is_lt(block, blocks))))

def clone.masks(lookup: Array<U32>, other_lookup: Array<U32>, +stride: U32, +rows: U32,
                   +blocks: U32, +used: U32, result: Array<U32> & Array<U32>) -> Profile & Profile:
  (masks, other_masks) = result
  (Profile{lookup, masks, stride, rows, blocks, used},
    Profile{other_lookup, other_masks, stride, rows, blocks, used})

def clone.lookup(masks: Array<U32>, stride: U32, rows: U32, blocks: U32, used: U32,
                    result: Array<U32> & Array<U32>) -> Profile & Profile:
  (lookup, other_lookup) = result
  clone.masks(lookup, other_lookup, stride, rows, blocks, used, Array.clone(U32, masks))

def clone(profile: Profile) -> Profile & Profile:
  Profile{lookup, masks, stride, rows, blocks, used} = profile
  clone.lookup(masks, stride, rows, blocks, used, Array.clone(U32, lookup))

def retained_bytes(profile: Profile) -> Profile & Nat:
  Profile{lookup, masks, +stride, +rows, blocks, used} = profile
  (Profile{lookup, masks, stride, rows, blocks, used},
    Nat.add(1024n, Nat.mul(4n, Nat.mul(U32.to_nat(stride), Nat.pow(2n, depth(U32.to_nat(rows)))))))
