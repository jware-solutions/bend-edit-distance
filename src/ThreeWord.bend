import Base
import ../EdlibTypes.bend as E
import ./Profile.bend as P
import ./BitVector.bend as V
import ./Word.bend as Word

# Three-word NW vertical differences and final bottom score. The caller
# validates stride 4 and 3 logical blocks. Row guards cover unknown bytes.
# Earlier score fields are unused until finish restores them from differences.
# Block carries and successive target columns stay sequential.
type State is Type:
  State{profile: P.Profile, b0: V.Block, b1: V.Block, b2: V.Block}

type Run is Type:
  Run{profile: P.Profile, b0: V.Block, b1: V.Block, b2: V.Block, distance: E.EditDistance}

# Geometry is fixed by the caller's shape check. Restore those constants
# while retaining the owned arrays; the normal profile accessor supplies padding.
def mask(profile: P.Profile, +row: U32, +block: U32) -> P.Profile & U32:
  P.Profile{lookup, masks, _, +rows, _, used} = profile
  P.mask.result(lookup, 4, rows, 3, used, block,
    P.mask_at(masks, U32.add(U32.mul(row, 4), block),
      Bool.and(U32.is_lt(row, rows), U32.is_lt(block, 3))))

def block2.updated(profile: P.Profile, b0: V.Block, b1: V.Block, value: V.Block & V.Carry) -> State:
  (b2, _) = value
  State{profile, b0, b1, b2}

def block2.masked(row: U32, b0: V.Block, b1: V.Block, b2: V.Block, carry: V.Carry, value: P.Profile & U32) -> State:
  (profile, eq) = value
  block2.updated(profile, b0, b1, V.calculate_block(b2, eq, carry))

def block1.updated(profile: P.Profile, +row: U32, b0: V.Block, b2: V.Block, value: V.Block & V.Carry) -> State:
  (V.Block{pv, mv, _}, carry) = value
  b1 = {V.Block{pv, mv, 0} : V.Block}
  block2.masked(row, b0, b1, b2, carry, mask(profile, row, 2))

def block1.masked(row: U32, b0: V.Block, b1: V.Block, b2: V.Block, carry: V.Carry, value: P.Profile & U32) -> State:
  (profile, eq) = value
  block1.updated(profile, row, b0, b2, V.calculate_block(b1, eq, carry))

def block0.updated(profile: P.Profile, +row: U32, b1: V.Block, b2: V.Block, value: V.Block & V.Carry) -> State:
  (V.Block{pv, mv, _}, carry) = value
  b0 = {V.Block{pv, mv, 0} : V.Block}
  block1.masked(row, b0, b1, b2, carry, mask(profile, row, 1))

def block0.masked(row: U32, b0: V.Block, b1: V.Block, b2: V.Block, carry: V.Carry, value: P.Profile & U32) -> State:
  (profile, eq) = value
  block0.updated(profile, row, b1, b2, V.calculate_block(b0, eq, carry))

def selected(b0: V.Block, b1: V.Block, b2: V.Block, value: P.Profile & U32) -> State:
  (profile, +row) = value
  block0.masked(row, b0, b1, b2, V.Carry{1, 0}, mask(profile, row, 0))

def finish_run(profile: P.Profile, b0: V.Block, b1: V.Block, b2: V.Block, padding: Nat) -> Run:
  V.Block{+pv, +mv, +score} = b2
  Run{profile, b0, b1, V.Block{pv, mv, score}, E.Found{U32.to_nat(V.decode_word(padding, pv, mv, score))}}

def restore0(profile: P.Profile, b0: V.Block, +b1: V.Block, b2: V.Block, padding: Nat) -> Run:
  V.Block{pv, mv, _} = b0
  next = {V.Block{pv, mv, V.previous_score(b1)} : V.Block}
  finish_run(profile, next, b1, b2, padding)

def restore1(profile: P.Profile, b0: V.Block, b1: V.Block, +b2: V.Block, padding: Nat) -> Run:
  V.Block{pv, mv, _} = b1
  next = {V.Block{pv, mv, V.previous_score(b2)} : V.Block}
  restore0(profile, b0, next, b2, padding)

def finish(state: State, padding: Nat) -> Run:
  State{profile, b0, b1, b2} = state
  restore1(profile, b0, b1, b2, padding)

def scan(target: String, +padding: Nat, state: State) -> Run:
  match target state:
    case SNil{} _:
      finish(state, padding)
    case SCon{symbol, tail} State{profile, b0, b1, b2}:
      scan(tail, padding, selected(b0, b1, b2, P.row(profile, Char.to_u32(symbol))))

def run(target: String, profile: P.Profile, padding: Nat) -> Run:
  scan(target, padding, State{profile, V.Block{Word.all_bits(), 0, U32.mul(1, Word.width_u32())},
    V.Block{Word.all_bits(), 0, U32.mul(2, Word.width_u32())},
    V.Block{Word.all_bits(), 0, U32.mul(3, Word.width_u32())}})
