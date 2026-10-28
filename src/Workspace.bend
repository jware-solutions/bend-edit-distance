import ./Word.bend as Word
import Base
import ./BitVector.bend as V
import ./Profile.bend as P

# Packed blocks compile to a flat array of three 64-bit terms in four-slot
# records. Each active block is in [first,last), within capacity. Ownership
# moves through the tail-recursive pass; masks are separate immutable data.
type Workspace is Type:
  Workspace{blocks: Array<V.Block>, capacity: U32, first: U32, last: U32}

type Updated is Type:
  Updated{profile: P.Profile, workspace: Workspace, score: U32, carry: V.Carry}

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

def column.row(workspace: Workspace, first: U32, count: Nat, carry: V.Carry,
                 result: P.Profile & U32) -> Updated:
  (profile, row) = result
  advance(count, first, row, Updated{profile, workspace, 0, carry})

def column(profile: P.Profile, workspace: Workspace, symbol: U32,
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
