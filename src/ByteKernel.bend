import Base
import ../EdlibTypes.bend as E
import ./ByteTarget.bend as BT
import ./Profile.bend as P
import ./Workspace.bend as W
import ./Word.bend as Word
import ./BitVector.bend as V
import ./SearchKernel.bend as K
import ./RetryHint.bend as Hint

# One buffer owner survives all attempts. The workspace and masks are owned
# independently; column transitions reuse the String kernel's band operations.
type Run is Type:
  Run{bytes: Array<U32>, result: K.Run}

type ByteColumn is Type:
  ByteColumn{bytes: Array<U32>, state: K.ColumnReady}

def finished(bytes: Array<U32>, result: K.Run) -> Run:
  Run{bytes, result}

def step(profile: P.Profile, workspace: W.Workspace, length: Nat, target_length: Nat,
             padding: Nat, column: Nat, maximum: Nat, index: U32, value: Array<U32> & U32) -> ByteColumn:
  (bytes, word) = value
  +symbol = BT.byte(word, index)
  ByteColumn{bytes, K.ready(K.step.updated(symbol, length, target_length, column, maximum, padding,
    W.column(profile, workspace, symbol, V.Carry{1, 0})))}

# The caller has checked the buffer's logical length. Fuel and the byte index
# advance together, so an array read never reaches the packed tail padding.
def nw(fuel: Nat, +index: U32, +length: Nat, +target_length: Nat, +padding: Nat,
           +column: Nat, blocks: Nat, state: ByteColumn) -> Run:
  match fuel state:
    case _ ByteColumn{bytes, K.ColumnReady{profile, workspace, _, work, True{}}}:
      Run{bytes, K.Run{profile, workspace, K.Stats{E.NotFound{}, Nat.add(blocks, work), column, 1n}}}
    case 0n ByteColumn{bytes, K.ColumnReady{profile, W.Workspace{data, +capacity, first, +last}, maximum, work, False{}}}:
      finished(bytes, K.finish(profile, W.Workspace{data, capacity, first, last}, maximum, padding,
        Nat.add(blocks, work), column, U32.is_eq(last, capacity)))
    case 1n+p ByteColumn{bytes, K.ColumnReady{profile, workspace, maximum, work, False{}}}:
      nw(p, U32.inc(index), length, target_length, padding, 1n+column, Nat.add(blocks, work),
        step(profile, workspace, length, target_length, padding, 1n+column, maximum, index,
          bytes[U32.shrn(index, BT.log_cell_bytes())]))

def attempt(bytes: Array<U32>, profile: P.Profile, workspace: W.Workspace,
                +length: Nat, +target_length: Nat, +maximum: Nat, padding: Nat) -> Run:
  nw(target_length, 0, length, target_length, padding, 0n, 0n,
    ByteColumn{bytes, K.ready(K.Step{profile,
      W.initialize(workspace, K.initial_count(length, target_length, maximum)), maximum, 0n})})

def accumulated(previous: K.Stats, value: Run) -> Run:
  Run{bytes, result} = value
  Run{bytes, K.accumulated(previous, result)}

def adaptive(fuel: Nat, +length: Nat, +target_length: Nat,
                 +maximum: Nat, +padding: Nat, value: Run) -> Run:
  match fuel value:
    case _ Run{bytes, K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}}:
      Run{bytes, K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}}
    case 0n _:
      value
    case 1n+p Run{bytes, K.Run{profile, workspace, stats}}:
      adaptive(p, length, target_length, Nat.min(Nat.max(length, target_length), Nat.mul(maximum, 2n)), padding,
        accumulated(stats, attempt(bytes, profile, workspace, length, target_length, maximum, padding)))

def finite(bytes: Array<U32>, profile: P.Profile, workspace: W.Workspace, +length: Nat,
               +target_length: Nat, +maximum: Nat, rejected: Bool) -> Run:
  match rejected:
    case True{}:
      Run{bytes, K.Run{profile, workspace, K.Stats{E.NotFound{}, 0n, 0n, 0n}}}
    case False{}:
      attempt(bytes, profile, workspace, length, target_length,
        Nat.min(maximum, Nat.max(length, target_length)), Word.padding(length))

type HintState is Type:
  HintState{bytes: Array<U32>, state: Hint.Scanning}

type HintRun is Type:
  HintRun{bytes: Array<U32>, value: Hint.Hinted}

def hint.bits(bytes: Array<U32>, index: U32, limit: Nat, distance: Nat, value: P.Profile & U32) -> HintState:
  HintState{bytes, Hint.bits(index, limit, distance, value)}

def hint.row(bytes: Array<U32>, +index: U32, limit: Nat, distance: Nat, value: P.Profile & U32) -> HintState:
  (profile, row) = value
  hint.bits(bytes, index, limit, distance, P.mask(profile, row, U32.shrn(index, Word.log_width())))

def hint.word(profile: P.Profile, +index: U32, limit: Nat, distance: Nat, value: Array<U32> & U32) -> HintState:
  (bytes, word) = value
  hint.row(bytes, index, limit, distance, P.row(profile, BT.byte(word, index)))

def hint.scan(fuel: Nat, +index: U32, +limit: Nat, state: HintState) -> HintRun:
  match fuel state:
    case _ HintState{bytes, Hint.Scanning{profile, _, True{}}}:
      HintRun{bytes, Hint.Hinted{profile, Hint.Unavailable{}}}
    case 0n HintState{bytes, Hint.Scanning{profile, distance, False{}}}:
      HintRun{bytes, Hint.Hinted{profile, Hint.Bounded{distance}}}
    case 1n+p HintState{bytes, Hint.Scanning{profile, distance, False{}}}:
      hint.scan(p, U32.inc(index), limit,
        hint.word(profile, index, limit, distance, bytes[U32.shrn(index, BT.log_cell_bytes())]))

def retry(+length: Nat, workspace: W.Workspace, stats: K.Stats, value: HintRun) -> Run:
  match value:
    case HintRun{bytes, Hint.Hinted{profile, Hint.Unavailable{}}}:
      adaptive(1n+length, length, length, Nat.mul(Word.width(), 2n), Word.padding(length),
        Run{bytes, K.Run{profile, workspace, stats}})
    case HintRun{bytes, Hint.Hinted{profile, Hint.Bounded{upper}}}:
      adaptive(1n+length, length, length, Nat.max(1n+Word.width(), upper), Word.padding(length),
        Run{bytes, K.Run{profile, workspace, stats}})

def first.failed(+length: Nat, bytes: Array<U32>, profile: P.Profile, workspace: W.Workspace, stats: K.Stats, useful: Bool) -> Run:
  match useful:
    case False{}:
      retry(length, workspace, stats, HintRun{bytes, Hint.Hinted{profile, Hint.Unavailable{}}})
    case True{}:
      retry(length, workspace, stats, hint.scan(length, 0, Hint.hint_limit(length), HintState{bytes, Hint.Scanning{profile, 0n, False{}}}))

def first(+length: Nat, value: Run) -> Run:
  match value:
    case Run{bytes, K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}}:
      Run{bytes, K.Run{profile, workspace, K.Stats{E.Found{distance}, blocks, columns, attempts}}}
    case Run{bytes, K.Run{profile, workspace, K.Stats{distance, blocks, +columns, attempts}}}:
      first.failed(length, bytes, profile, workspace, K.Stats{distance, blocks, columns, attempts}, Hint.use_hint(length, columns))

def unlimited(bytes: Array<U32>, profile: P.Profile, workspace: W.Workspace, +length: Nat, +columns: Nat, eligible: Bool) -> Run:
  match eligible:
    case True{}:
      first(length, attempt(bytes, profile, workspace, length, length, Word.width(), Word.padding(length)))
    case False{}:
      adaptive(1n+Nat.max(length, columns), length, columns,
        Nat.min(Nat.max(length, columns), Nat.max(Word.width(), Nat.max(Nat.sub(columns, length), Nat.sub(length, columns)))),
        Word.padding(length), Run{bytes, K.Run{profile, workspace, K.Stats{E.NotFound{}, 0n, 0n, 0n}}})

def search_owned(target: BT.Target, profile: P.Profile, workspace: W.Workspace,
                     +length: Nat, threshold: E.Threshold) -> Run:
  BT.Target{bytes, +columns} = target
  match threshold:
    case E.MaxDistance{+maximum}:
      finite(bytes, profile, workspace, length, columns, maximum,
        Nat.is_lt(maximum, Nat.max(Nat.sub(length, columns), Nat.sub(columns, length))))
    case E.Unlimited{}:
      unlimited(bytes, profile, workspace, length, columns,
        Bool.and(Nat.is_eq(length, columns), Bool.and(Nat.is_ge(length, Nat.mul(Word.width(), 32n)), Nat.is_le(length, 2147483647n))))

def result(value: Run) -> K.Run:
  Run{_, result} = value
  result

def search(target: BT.Target, profile: P.Profile, workspace: W.Workspace,
               length: Nat, threshold: E.Threshold) -> K.Run:
  result(search_owned(target, profile, workspace, length, threshold))
