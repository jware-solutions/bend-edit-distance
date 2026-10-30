import Base
import ../EdlibTypes.bend as E
import ./Profile.bend as P
import ./BitVector.bend as V
import ./Word.bend as Word

# Complete two-word NW state. The first carry feeds the second block, and
# both feed the next target column; none of these transitions can fork.
type State is Type:
  State{profile: P.Profile, first: V.Block, second: V.Block}

type Run is Type:
  Run{profile: P.Profile, first: V.Block, second: V.Block, distance: E.EditDistance}

def second.updated(profile: P.Profile, first: V.Block, value: V.Block & V.Carry) -> State:
  (second, _) = value
  State{profile, first, second}

def second.masked(first: V.Block, second: V.Block, carry: V.Carry,
                     value: P.Profile & U32) -> State:
  (profile, eq) = value
  second.updated(profile, first, V.calculate_block(second, eq, carry))

def first.updated(profile: P.Profile, row: U32, second: V.Block, value: V.Block & V.Carry) -> State:
  (first, carry) = value
  second.masked(first, second, carry, P.mask(profile, row, 1))

def first.masked(row: U32, first: V.Block, second: V.Block, value: P.Profile & U32) -> State:
  (profile, eq) = value
  first.updated(profile, row, second, V.calculate_block(first, eq, V.Carry{1, 0}))

def selected(first: V.Block, second: V.Block, value: P.Profile & U32) -> State:
  (profile, +row) = value
  first.masked(row, first, second, P.mask(profile, row, 0))

def scan(target: String, +padding: Nat, state: State) -> Run:
  match target state:
    case SNil{} State{profile, first, V.Block{+pv, +mv, +score}}:
      Run{profile, first, V.Block{pv, mv, score}, E.Found{U32.to_nat(V.decode_word(padding, pv, mv, score))}}
    case SCon{symbol, tail} State{profile, first, second}:
      scan(tail, padding, selected(first, second, P.row(profile, Char.to_u32(symbol))))

def run(target: String, profile: P.Profile, padding: Nat) -> Run:
  scan(target, padding, State{profile, V.Block{Word.all_bits(), 0, Word.width_u32()},
    V.Block{Word.all_bits(), 0, U32.mul(2, Word.width_u32())}})
