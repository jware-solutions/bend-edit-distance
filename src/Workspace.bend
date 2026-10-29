import ./Word.bend as Word
import Base
import ./BitVector.bend as V
import ./Profile.bend as P

# Packed blocks compile to three U32 values in four-slot, 16-byte records.
# Each active block is in [first,last), within capacity. Ownership
# moves through the tail-recursive pass; masks are separate immutable data.
type Workspace is Type:
  Workspace{blocks: Array<V.Block>, capacity: U32, first: U32, last: U32}

type Updated is Type:
  Updated{profile: P.Profile, workspace: Workspace, score: U32, carry: V.Carry}

# Include physical power-of-two rounding, including the zero-capacity buffer.
def storage_bytes(count: Nat) -> Nat:
  Nat.mul(16n, Nat.pow(2n, P.depth(count)))

def new(+count: Nat) -> Workspace:
  Workspace{Array.new(V.Block, P.depth(count), V.Block{Word.all_bits(), 0, 0}), U32.from_nat(count), 0, 0}

def bounds(workspace: Workspace, first: U32, last: U32) -> Workspace:
  Workspace{data, capacity, _, _} = workspace
  Workspace{data, capacity, first, last}

def put(workspace: Workspace, index: U32, block: V.Block) -> Workspace:
  Workspace{data, capacity, first, last} = workspace
  Workspace{Array.set(V.Block, data, index, block), capacity, first, last}

def get.result(capacity: U32, first: U32, last: U32, result: Array<V.Block> & V.Block) -> Workspace & V.Block:
  (data, block) = result
  (Workspace{data, capacity, first, last}, block)

def get(workspace: Workspace, index: U32) -> Workspace & V.Block:
  Workspace{data, capacity, first, last} = workspace
  get.result(capacity, first, last, Array.get(V.Block, data, index))

def score.result(result: Workspace & V.Block) -> Workspace & U32:
  (workspace, block) = result
  V.Block{_, _, score} = block
  (workspace, score)

def score(workspace: Workspace, index: U32) -> Workspace & U32:
  score.result(get(workspace, index))

def reset(fuel: Nat, +index: U32, workspace: Workspace) -> Workspace:
  match fuel:
    case 0n:
      workspace
    case 1n+p:
      reset(p, U32.inc(index), put(workspace, index,
        V.Block{Word.all_bits(), 0, U32.shln(U32.inc(index), Word.log_width())}))

def initialize(workspace: Workspace, +count: Nat) -> Workspace:
  reset(count, 0, bounds(workspace, 0, U32.from_nat(count)))

def update.calculated(profile: P.Profile, workspace: Workspace, +index: U32,
                        result: V.Block & V.Carry) -> Updated:
  (block, carry) = result
  V.Block{+pv, +mv, +score} = block
  Updated{profile, put(workspace, index, V.Block{pv, mv, score}), score, carry}

def update.block(profile: P.Profile, index: U32, eq: U32, carry: V.Carry,
                   result: Workspace & V.Block) -> Updated:
  (workspace, block) = result
  update.calculated(profile, workspace, index, V.calculate_block(block, eq, carry))

def update.mask(workspace: Workspace, +index: U32, carry: V.Carry,
                  result: P.Profile & U32) -> Updated:
  (profile, eq) = result
  update.block(profile, index, eq, carry, get(workspace, index))

def update(profile: P.Profile, workspace: Workspace, row: U32, +index: U32,
              carry: V.Carry) -> Updated:
  update.mask(workspace, index, carry, P.mask(profile, row, index))

def advance(fuel: Nat, +index: U32, +row: U32, state: Updated) -> Updated:
  match fuel state:
    case 0n _:
      state
    case 1n+p Updated{profile, workspace, _, carry}:
      advance(p, U32.inc(index), row, update(profile, workspace, row, index, carry))

# Wide active bands select and validate a symbol's row once per column.
# The offset is invariant across its sequential block updates. Small bands
# retain the original transition, including unknown-symbol padding masks.
def selected.read(lookup: Array<U32>, stride: U32, rows: U32, +blocks: U32, +used: U32,
                     +index: U32, carry: V.Carry, workspace: Workspace, result: Array<U32> & U32) -> Updated:
  (masks, bits) = result
  update.block(P.Profile{lookup, masks, stride, rows, blocks, used}, index, U32.or(bits, P.padding_mask(used, U32.is_eq(U32.inc(index), blocks))), carry,
    get(workspace, index))

def selected(profile: P.Profile, workspace: Workspace, base: U32, +index: U32, carry: V.Carry) -> Updated:
  P.Profile{lookup, masks, stride, rows, blocks, used} = profile
  selected.read(lookup, stride, rows, blocks, used, index, carry, workspace,
    Array.get(U32, masks, U32.add(base, index)))

def advance_selected(fuel: Nat, +index: U32, +base: U32, state: Updated) -> Updated:
  match fuel state:
    case 0n _:
      state
    case 1n+p Updated{profile, workspace, _, carry}:
      advance_selected(p, U32.inc(index), base, selected(profile, workspace, base, index, carry))

def column.selected(workspace: Workspace, first: U32, count: Nat, carry: V.Carry,
                       profile: P.Profile, row: U32, base: U32, valid: Bool) -> Updated:
  match valid:
    case True{}:
      advance_selected(count, first, base, Updated{profile, workspace, 0, carry})
    case False{}:
      advance(count, first, row, Updated{profile, workspace, 0, carry})

def column.row_selected(workspace: Workspace, +first: U32, +count: Nat, carry: V.Carry,
                 result: P.Profile & U32) -> Updated:
  Workspace{data, capacity, +begin, +last} = workspace
  (profile, +row) = result
  P.Profile{lookup, masks, +stride, +rows, +blocks, used} = profile
  column.selected(Workspace{data, capacity, begin, last}, first, count, carry,
    P.Profile{lookup, masks, stride, rows, blocks, used}, row, U32.mul(row, stride),
    Bool.and(U32.is_lt(row, rows), Bool.and(U32.is_le(begin, last), Bool.and(U32.is_le(last, blocks),
      Nat.is_le(Nat.add(U32.to_nat(first), count), U32.to_nat(blocks))))))

def column.row(workspace: Workspace, first: U32, count: Nat, carry: V.Carry,
                       result: P.Profile & U32) -> Updated:
  (profile, row) = result
  advance(count, first, row, Updated{profile, workspace, 0, carry})

def column.choose(profile: P.Profile, workspace: Workspace, symbol: U32,
                     first: U32, count: Nat, carry: V.Carry, fast: Bool) -> Updated:
  match fast:
    case True{}:
      column.row_selected(workspace, first, count, carry, P.row(profile, symbol))
    case False{}:
      column.row(workspace, first, count, carry, P.row(profile, symbol))

def column(profile: P.Profile, workspace: Workspace, symbol: U32,
              carry: V.Carry) -> Updated:
  Workspace{data, +capacity, +first, +last} = workspace
  +count = U32.sub(last, first)
  column.choose(profile, Workspace{data, capacity, first, last}, symbol, first,
    U32.to_nat(count), carry, Bool.and(U32.is_ge(capacity, 32), U32.is_ge(count, 8)))

# The original guarded transition remains an executable equivalence oracle.
def column_reference(profile: P.Profile, workspace: Workspace, symbol: U32,
                        carry: V.Carry) -> Updated:
  Workspace{data, capacity, +first, +last} = workspace
  column.row(Workspace{data, capacity, first, last}, first,
    U32.to_nat(U32.sub(last, first)), carry, P.row(profile, symbol))

def last_score.result(padding: Nat, result: Workspace & V.Block) -> Workspace & U32:
  (workspace, block) = result
  V.Block{pv, mv, score} = block
  (workspace, V.decode_word(padding, pv, mv, score))

def last_score(workspace: Workspace, padding: Nat) -> Workspace & U32:
  Workspace{data, capacity, first, +last} = workspace
  last_score.result(padding,
    get(Workspace{data, capacity, first, last}, U32.sub(last, 1)))

def capacity(workspace: Workspace) -> U32:
  Workspace{_, count, _, _} = workspace
  count

def block_value(result: Workspace & V.Block) -> V.Block:
  (_, block) = result
  block
