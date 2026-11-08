import Base
import ../EdlibTypes.bend as E
import ../src/Word.bend as Word
import ../src/BitVector.bend as V
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/SearchKernel.bend as K
import ../src/ByteKernel.bend as Bytes
import ../src/ByteTarget.bend as BT

# Internal forced-distance experiment. Production dispatch does not import it.
# Preconditions: nonempty supported byte query, matching profile/workspace,
# lengths <= INT_MAX. Padded bottoms are <= INT_MAX+31, and any DP score
# is <= max(padded query length,target length), strictly below UINT32_MAX.
# Exact full frontier, independent of the adaptive band. Every logical block
# is reset even when this owner previously held a trimmed or rejected band.
# A dense pass is one attempt; counters charge its actual columns and blocks.
def initialize(profile: P.Profile, workspace: W.Workspace, length: Nat) -> W.Updated:
  W.Updated{profile, W.initialize(workspace, Word.blocks(length)), 0, V.Carry{1, 0}}

def string.scan(target: String, +padding: Nat, +columns: Nat, +work: Nat,
                   state: W.Updated) -> K.Run:
  match target state:
    case SNil{} W.Updated{profile, workspace, _, _}:
      K.finish(profile, workspace, 4294967295n, padding, work, columns, True{})
    case SCon{h, t} W.Updated{profile, workspace, _, _}:
      string.scan(t, padding, columns, work,
        W.column(profile, workspace, Char.to_u32(h), V.Carry{1, 0}))

def string(target: String, profile: P.Profile, workspace: W.Workspace,
              +length: Nat, +columns: Nat) -> K.Run:
  match length:
    case 0n:
      K.Run{profile, workspace, K.Stats{E.Found{columns}, 0n, 0n, 0n}}
    case 1n+p:
      +count = Word.blocks(1n+p)
      string.scan(target, Word.padding(1n+p), columns, Nat.mul(count, columns),
        initialize(profile, workspace, 1n+p))

def packed.updated(bytes: Array<U32>, value: W.Updated) -> Bytes.ByteColumn:
  W.Updated{profile, workspace, _, _} = value
  Bytes.ByteColumn{bytes, K.ColumnReady{profile, workspace, 0n, 0n, False{}}}

def packed.read(profile: P.Profile, workspace: W.Workspace, +index: U32,
                   value: Array<U32> & U32) -> Bytes.ByteColumn:
  (bytes, word) = value
  packed.updated(bytes, W.column(profile, workspace, BT.byte(word, index), V.Carry{1, 0}))

def packed.scan(fuel: Nat, +index: U32, +padding: Nat, +columns: Nat,
                   +work: Nat, state: Bytes.ByteColumn) -> Bytes.Run:
  match fuel state:
    case 0n Bytes.ByteColumn{bytes, K.ColumnReady{profile, workspace, _, _, _}}:
      Bytes.Run{bytes, K.finish(profile, workspace, 4294967295n, padding, work, columns, True{})}
    case 1n+p Bytes.ByteColumn{bytes, K.ColumnReady{profile, workspace, _, _, _}}:
      packed.scan(p, U32.inc(index), padding, columns, work,
        packed.read(profile, workspace, index, bytes[U32.shrn(index, BT.log_cell_bytes())]))

def packed(target: BT.Target, profile: P.Profile, workspace: W.Workspace, +length: Nat) -> Bytes.Run:
  BT.Target{bytes, +columns} = target
  match length:
    case 0n:
      Bytes.Run{bytes, K.Run{profile, workspace, K.Stats{E.Found{columns}, 0n, 0n, 0n}}}
    case 1n+p:
      +count = Word.blocks(1n+p)
      packed.scan(columns, 0, Word.padding(1n+p), columns, Nat.mul(count, columns),
        packed.updated(bytes, initialize(profile, workspace, 1n+p)))

# A deliberately conservative Nat guard runs before any index narrowing.
# The padded query + target bounds every DP score (the delete/insert path),
# with one extra unit reserved for calculate_block's intermediate addition.
# Unsupported dimensions retain the unchanged banded route.
def work_room(length: Nat, columns: Nat) -> Bool:
  # Under the INT_MAX dimension guard, blocks <= 2^26 and columns < 2^31.
  # Either blocks <= 2^17 or columns < 2^22 then gives work < 2^48, the
  # pinned Nat limit. No oversized product is evaluated to test admission.
  Bool.or(Nat.is_le(Word.blocks(length), 131072n), Nat.is_le(columns, 4194303n))

def budget(+length: Nat, +columns: Nat) -> Bool:
  Bool.and(work_room(length, columns),
    Nat.is_le(Nat.add(Nat.mul(Word.blocks(length), Word.width()), columns), 4294967294n))

def supported_lengths(length: Nat, columns: Nat, valid: Bool) -> Bool:
  match valid:
    case False{}:
      False{}
    case True{}:
      budget(length, columns)

def supported(+length: Nat, +columns: Nat) -> Bool:
  supported_lengths(length, columns,
    Bool.and(Nat.is_le(length, 2147483647n), Nat.is_le(columns, 2147483647n)))

def filtered(threshold: E.Threshold, value: K.Run) -> K.Run:
  K.Run{profile, workspace, K.Stats{distance, blocks, columns, attempts}} = value
  match distance:
    case E.NotFound{}:
      K.Run{profile, workspace, K.Stats{E.NotFound{}, blocks, columns, attempts}}
    case E.Found{+score}:
      K.Run{profile, workspace, K.Stats{Bool.pick(E.EditDistance,
        E.within_threshold(threshold, score), E.Found{score}, E.NotFound{}), blocks, columns, attempts}}

def choose(target: String, profile: P.Profile, workspace: W.Workspace,
               +length: Nat, +columns: Nat, threshold: E.Threshold, supported: Bool) -> K.Run:
  match supported:
    case False{}:
      K.search(target, profile, workspace, length, columns, threshold)
    case True{}:
      filtered(threshold, string(target, profile, workspace, length, columns))

def finite(target: String, profile: P.Profile, workspace: W.Workspace,
               +length: Nat, +columns: Nat, maximum: Nat, rejected: Bool) -> K.Run:
  match rejected:
    case True{}:
      K.Run{profile, workspace, K.Stats{E.NotFound{}, 0n, 0n, 0n}}
    case False{}:
      choose(target, profile, workspace, length, columns, E.MaxDistance{maximum}, supported(length, columns))

def search(target: String, profile: P.Profile, workspace: W.Workspace,
               +length: Nat, +columns: Nat, threshold: E.Threshold) -> K.Run:
  match length columns threshold:
    case 0n _ _:
      K.Run{profile, workspace, K.Stats{E.Found{columns}, 0n, 0n, 0n}}
    case _ 0n _:
      K.Run{profile, workspace, K.Stats{E.Found{length}, 0n, 0n, 0n}}
    case _ _ E.MaxDistance{+maximum}:
      finite(target, profile, workspace, length, columns, maximum,
        Nat.is_lt(maximum, Nat.max(Nat.sub(length, columns), Nat.sub(columns, length))))
    case _ _ E.Unlimited{}:
      choose(target, profile, workspace, length, columns, E.Unlimited{}, supported(length, columns))

