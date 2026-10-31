import Base
import ../EdlibTypes.bend as E
import ./Profile.bend as P
import ./Workspace.bend as W
import ./SearchKernel.bend as K
import ./Word.bend as Word

# A bounded diagonal alignment gives an upper bound, never an optimum.
# Only the owned masks are read; literal/equality matches share one definition.
type Hint is Data:
  Unavailable{}
  Bounded{distance: Nat}

type Hinted is Type:
  Hinted{profile: P.Profile, hint: Hint}

type Scanning is Type:
  Scanning{profile: P.Profile, distance: Nat, exceeded: Bool}

def bits(+index: U32, +limit: Nat, distance: Nat, value: P.Profile & U32) -> Scanning:
  (profile, bits) = value
  +updated = Nat.add(distance, Bool.pick(Nat, U32.is_eq(U32.and(bits, Word.literal_bit(index)), 0), 1n, 0n))
  Scanning{profile, updated, Nat.is_gt(updated, limit)}

def selected(+index: U32, limit: Nat, distance: Nat, value: P.Profile & U32) -> Scanning:
  (profile, row) = value
  bits(index, limit, distance, P.mask(profile, row, U32.shrn(index, Word.log_width())))

def scan(fuel: Nat, target: String, +index: U32, +limit: Nat, state: Scanning) -> Hinted:
  match fuel target state:
    case _ _ Scanning{profile, _, True{}}:
      Hinted{profile, Unavailable{}}
    case 0n SNil{} Scanning{profile, distance, False{}}:
      Hinted{profile, Bounded{distance}}
    case 0n _ Scanning{profile, _, _}:
      Hinted{profile, Unavailable{}}
    case _ SNil{} Scanning{profile, _, _}:
      Hinted{profile, Unavailable{}}
    case 1n+p SCon{symbol, tail} Scanning{profile, distance, False{}}:
      scan(p, tail, U32.inc(index), limit, selected(index, limit, distance, P.row(profile, Char.to_u32(symbol))))

def retry(+target: String, +length: Nat, workspace: W.Workspace, stats: K.Stats, value: Hinted) -> K.Run:
  match value:
    case Hinted{profile, Unavailable{}}:
      K.adaptive(1n+length, target, length, length, Nat.mul(Word.width(), 2n), Word.padding(length),
        K.Run{profile, workspace, stats})
    case Hinted{profile, Bounded{upper}}:
      K.adaptive(1n+length, target, length, length, Nat.max(1n+Word.width(), upper), Word.padding(length),
        K.Run{profile, workspace, stats})

# Search checks length <= INT_MAX before calling this word-sized policy.
def hint_limit_word(+length: U32) -> U32:
  U32.min(U32.shrn(length, 3n),
    U32.max(U32.mul(Word.width_u32(), 8), U32.shrn(length, Word.log_width())))

def hint_limit(length: Nat) -> Nat:
  U32.to_nat(hint_limit_word(U32.from_nat(length)))

def failed(+target: String, +length: Nat, profile: P.Profile, workspace: W.Workspace, stats: K.Stats, useful: Bool) -> K.Run:
  match useful:
    case False{}:
      retry(target, length, workspace, stats, Hinted{profile, Unavailable{}})
    case True{}:
      retry(target, length, workspace, stats, scan(length, target, 0, hint_limit(length), Scanning{profile, 0n, False{}}))

# Retry hints are useful only after an intermediate amount of progress.
# Earlier failures are unlikely to fit the bound; later failures often need
# only the ordinary next threshold. All decisions preserve normal fallback.
# Split the product before division so length * width never overflows U32.
def minimum_columns(+length: U32) -> U32:
  +divisor = U32.max(1, hint_limit_word(length))
  U32.add(U32.mul(U32.div(length, divisor), Word.width_u32()),
    U32.div(U32.mul(U32.mod(length, divisor), Word.width_u32()), divisor))

def use_hint_word(+length: U32, +consumed: U32) -> Bool:
  Bool.and(U32.is_ge(consumed, minimum_columns(length)),
    Bool.and(U32.is_lt(consumed, length), U32.is_lt(consumed, U32.sub(length, consumed))))

def use_hint(length: Nat, consumed: Nat) -> Bool:
  use_hint_word(U32.from_nat(length), U32.from_nat(consumed))

def first(+target: String, +length: Nat, value: K.Run) -> K.Run:
  match value:
    case K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}:
      K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}
    case K.Run{profile, workspace, K.Stats{distance, blocks, +columns, attempts}}:
      failed(target, length, profile, workspace, K.Stats{distance, blocks, columns, attempts},
        use_hint(length, columns))

def choose(+target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat,
               columns: Nat, eligible: Bool) -> K.Run:
  match eligible:
    case False{}:
      K.search(target, profile, workspace, length, columns, E.Unlimited{})
    case True{}:
      first(target, length, K.attempt(target, profile, workspace, length, length, Word.width(), Word.padding(length)))

# Guard equal dimensions and U32 indexing before the diagonal scan.
# Query/target lengths outside this policy retain ordinary adaptive search.
def search(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat, +columns: Nat) -> K.Run:
  choose(target, profile, workspace, length, columns,
    Bool.and(Nat.is_eq(length, columns), Bool.and(Nat.is_ge(length, Nat.mul(Word.width(), 32n)), Nat.is_le(length, 2147483647n))))
