import Base
import ../EdlibTypes.bend as E
import ./Profile.bend as P
import ./BitVector.bend as V
import ./Word.bend as Word

# One nonempty query word, unlimited NW. Carry and target columns remain
# sequential; the entire block state stays in scalar values between columns.
type State is Type:
  State{profile: P.Profile, block: V.Block}

type Run is Type:
  Run{profile: P.Profile, block: V.Block, distance: E.EditDistance}

def updated(profile: P.Profile, result: V.Block & V.Carry) -> State:
  (block, _) = result
  State{profile, block}

def masked(block: V.Block, result: P.Profile & U32) -> State:
  (profile, eq) = result
  updated(profile, V.calculate_block(block, eq, V.Carry{1, 0}))

def selected(block: V.Block, result: P.Profile & U32) -> State:
  (profile, row) = result
  masked(block, P.mask(profile, row, 0))

def scan(target: String, +padding: Nat, state: State) -> Run:
  match target state:
    case SNil{} State{profile, V.Block{+pv, +mv, +score}}:
      Run{profile, V.Block{pv, mv, score}, E.Found{U32.to_nat(V.decode_word(padding, pv, mv, score))}}
    case SCon{symbol, tail} State{profile, block}:
      scan(tail, padding, selected(block, P.row(profile, Char.to_u32(symbol))))

def run(target: String, profile: P.Profile, padding: Nat) -> Run:
  scan(target, padding, State{profile, V.Block{Word.all_bits(), 0, Word.width_u32()}})
