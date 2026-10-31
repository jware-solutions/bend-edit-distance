import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ./ByteTarget.bend as BT
import ./Profile.bend as P
import ./Workspace.bend as W
import ./SingleWord.bend as SW
import ./TwoWord.bend as TW
import ./BitVector.bend as V
import ./Word.bend as Word
import ./SearchKernel.bend as K

# Search columns and block carries remain sequential. A target's one array
# owner passes through the scan, then is disposed in constant space.
type OneState is Type:
  OneState{bytes: Array<U32>, state: SW.State}

type TwoState is Type:
  TwoState{bytes: Array<U32>, state: TW.State}

def one.symbol(state: SW.State, symbol: U32) -> SW.State:
  SW.State{profile, block} = state
  SW.selected(block, P.row(profile, symbol))

def one.remaining(fuel: Nat, +word: U32, state: SW.State) -> SW.State:
  match fuel:
    case 0n:
      state
    case 1n+p:
      one.remaining(p, U32.shrn(word, 8n), one.symbol(state, U32.and(word, 255)))

def one.word(+word: U32, state: SW.State) -> SW.State:
  +second = U32.shrn(word, 8n)
  +third = U32.shrn(second, 8n)
  fourth = U32.shrn(third, 8n)
  one.symbol(one.symbol(one.symbol(one.symbol(state, U32.and(word, 255)),
    U32.and(second, 255)), U32.and(third, 255)), U32.and(fourth, 255))

def one.finish(state: SW.State, padding: Nat) -> SW.Run:
  SW.State{profile, V.Block{+pv, +mv, +score}} = state
  SW.Run{profile, V.Block{pv, mv, score}, E.Found{U32.to_nat(V.decode_word(padding, pv, mv, score))}}

def one.end.read(state: SW.State, padding: Nat, remaining: Nat,
                       value: Array<U32> & U32) -> SW.Run:
  (_, word) = value
  one.finish(one.remaining(remaining, word, state), padding)

def one.end(index: U32, remaining: Nat, padding: Nat, value: OneState) -> SW.Run:
  match remaining value:
    case 0n OneState{_, state}:
      one.finish(state, padding)
    case 1n+p OneState{bytes, state}:
      one.end.read(state, padding, 1n+p, bytes[index])

def one.word.read(state: SW.State, value: Array<U32> & U32) -> OneState:
  (bytes, word) = value
  OneState{bytes, one.word(word, state)}

def one.words(fuel: Nat, +index: U32, +remaining: Nat, +padding: Nat, value: OneState) -> SW.Run:
  match fuel value:
    case 0n _:
      one.end(index, remaining, padding, value)
    case 1n+p OneState{bytes, state}:
      one.words(p, U32.inc(index), remaining, padding, one.word.read(state, bytes[index]))

def two.symbol(state: TW.State, symbol: U32) -> TW.State:
  TW.State{profile, first, second} = state
  TW.selected(first, second, P.row(profile, symbol))

def two.remaining(fuel: Nat, +word: U32, state: TW.State) -> TW.State:
  match fuel:
    case 0n:
      state
    case 1n+p:
      two.remaining(p, U32.shrn(word, 8n), two.symbol(state, U32.and(word, 255)))

def two.word(+word: U32, state: TW.State) -> TW.State:
  +second = U32.shrn(word, 8n)
  +third = U32.shrn(second, 8n)
  fourth = U32.shrn(third, 8n)
  two.symbol(two.symbol(two.symbol(two.symbol(state, U32.and(word, 255)),
    U32.and(second, 255)), U32.and(third, 255)), U32.and(fourth, 255))

def two.finish(state: TW.State, padding: Nat) -> TW.Run:
  TW.State{profile, first, V.Block{+pv, +mv, +score}} = state
  TW.Run{profile, first, V.Block{pv, mv, score}, E.Found{U32.to_nat(V.decode_word(padding, pv, mv, score))}}

def two.end.read(state: TW.State, padding: Nat, remaining: Nat,
                       value: Array<U32> & U32) -> TW.Run:
  (_, word) = value
  two.finish(two.remaining(remaining, word, state), padding)

def two.end(index: U32, remaining: Nat, padding: Nat, value: TwoState) -> TW.Run:
  match remaining value:
    case 0n TwoState{_, state}:
      two.finish(state, padding)
    case 1n+p TwoState{bytes, state}:
      two.end.read(state, padding, 1n+p, bytes[index])

def two.word.read(state: TW.State, value: Array<U32> & U32) -> TwoState:
  (bytes, word) = value
  TwoState{bytes, two.word(word, state)}

def two.words(fuel: Nat, +index: U32, +remaining: Nat, +padding: Nat, value: TwoState) -> TW.Run:
  match fuel value:
    case 0n _:
      two.end(index, remaining, padding, value)
    case 1n+p TwoState{bytes, state}:
      two.words(p, U32.inc(index), remaining, padding, two.word.read(state, bytes[index]))

def run(target: BT.Target, profile: P.Profile, workspace: W.Workspace, +length: Nat, one: Bool) -> K.Run:
  BT.Target{bytes, +columns} = target
  match one:
    case True{}:
      Q.run_nw.result(workspace, columns, one.words(Nat.div(columns, BT.cell_bytes()), 0, Nat.mod(columns, BT.cell_bytes()), Word.padding(length),
        OneState{bytes, SW.State{profile, V.Block{Word.all_bits(), 0, Word.width_u32()}}}))
    case False{}:
      Q.run_nw.two.result(workspace, columns, two.words(Nat.div(columns, BT.cell_bytes()), 0, Nat.mod(columns, BT.cell_bytes()), Word.padding(length),
        TwoState{bytes, TW.State{profile, V.Block{Word.all_bits(), 0, Word.width_u32()},
          V.Block{Word.all_bits(), 0, U32.mul(2, Word.width_u32())}}}))

type Known is Type:
  Known{query: String, pairs: List<&2, E.EqualityPair>, length: Nat, profile: P.Profile, workspace: W.Workspace}

type View is Type:
  ReadyOwner{state: Known}
  OtherOwner{prepared: Q.Prepared}

def view.choose(query: String, pairs: List<&2, E.EqualityPair>, length: Nat,
                    profile: P.Profile, workspace: W.Workspace, supported: Bool) -> View:
  match supported:
    case True{}:
      ReadyOwner{Known{query, pairs, length, profile, workspace}}
    case False{}:
      OtherOwner{Q.Prepared{query, pairs, length, Some{profile}, workspace}}

def view.profile(query: String, pairs: List<&2, E.EqualityPair>, +length: Nat,
                     profile: P.Profile, workspace: W.Workspace) -> View:
  P.Profile{lookup, masks, +stride, rows, +blocks, used} = profile
  W.Workspace{data, +capacity, first, last} = workspace
  view.choose(query, pairs, length, P.Profile{lookup, masks, stride, rows, blocks, used},
    W.Workspace{data, capacity, first, last}, Bool.or(Q.single_word(length, stride, blocks, capacity),
      Q.two_word(length, stride, blocks, capacity)))

def view(prepared: Q.Prepared) -> View:
  match prepared:
    case Q.Prepared{query, pairs, length, Some{profile}, workspace}:
      view.profile(query, pairs, length, profile, workspace)
    case _:
      OtherOwner{prepared}

def owner(state: Known) -> Q.Prepared:
  Known{query, pairs, length, profile, workspace} = state
  Q.Prepared{query, pairs, length, Some{profile}, workspace}

def distance_result(columns: Nat, distance: E.EditDistance) -> E.AlignResult:
  match distance:
    case E.Found{d}:
      E.distance_result(d, E.end_coordinate(columns), True{})
    case _:
      E.not_found()

def aligned(query: String, pairs: List<&2, E.EqualityPair>, length: Nat, columns: Nat,
                value: K.Run) -> Known & E.AlignResult:
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = value
  (Known{query, pairs, length, profile, workspace}, distance_result(columns, distance))

def error() -> E.AlignResult:
  E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}

def known.checked(state: Known, target: BT.Checked) -> Known & E.AlignResult:
  match state target:
    case _ BT.Checked{_, False{}}:
      (state, error())
    case Known{query, pairs, +length, profile, workspace} BT.Checked{BT.Target{_, 0n}, True{}}:
      (Known{query, pairs, length, profile, workspace}, E.distance_result(length, E.BeforeStart{}, True{}))
    case Known{query, pairs, +length, profile, workspace} BT.Checked{BT.Target{bytes, +columns}, True{}}:
      aligned(query, pairs, length, columns,
        run(BT.Target{bytes, columns}, profile, workspace, length, Nat.is_le(length, Word.width())))

def known(state: Known, target: BT.Target) -> Known & E.AlignResult:
  known.checked(state, BT.checked(target))

def fallback(prepared: Q.Prepared, target: BT.Checked) -> Q.Prepared & E.AlignResult:
  match target:
    case BT.Checked{_, False{}}:
      (prepared, error())
    case BT.Checked{BT.Target{bytes, +length}, True{}}:
      Q.align_sized_known(prepared, BT.string(BT.Target{bytes, length}), Q.default_options(), length, True{})

def aligned.owner(value: Known & E.AlignResult) -> Q.Prepared & E.AlignResult:
  (state, result) = value
  (owner(state), result)

def align.view(target: BT.Target, value: View) -> Q.Prepared & E.AlignResult:
  match value:
    case ReadyOwner{state}:
      aligned.owner(known(state, target))
    case OtherOwner{prepared}:
      fallback(prepared, BT.checked(target))

def align(prepared: Q.Prepared, target: BT.Target) -> Q.Prepared & E.AlignResult:
  align.view(target, view(prepared))

type BatchState is Type:
  BatchState{state: Known, results: List<&2, E.AlignResult>}

def batch.updated(results: List<&2, E.AlignResult>, value: Known & E.AlignResult) -> BatchState:
  (state, result) = value
  BatchState{state, result <> results}

def batch(values: List<&1, BT.Target>, state: BatchState) -> Q.Prepared & List<&2, E.AlignResult>:
  match values state:
    case Nil{} BatchState{state, results}:
      (owner(state), List.reverse(&2, E.AlignResult, results))
    case target <> tail BatchState{state, results}:
      batch(tail, batch.updated(results, known(state, target)))

type OtherState is Type:
  OtherState{prepared: Q.Prepared, results: List<&2, E.AlignResult>}

def other.updated(results: List<&2, E.AlignResult>, value: Q.Prepared & E.AlignResult) -> OtherState:
  (prepared, result) = value
  OtherState{prepared, result <> results}

def other(values: List<&1, BT.Target>, state: OtherState) -> Q.Prepared & List<&2, E.AlignResult>:
  match values state:
    case Nil{} OtherState{prepared, results}:
      (prepared, List.reverse(&2, E.AlignResult, results))
    case target <> tail OtherState{prepared, results}:
      other(tail, other.updated(results, align(prepared, target)))

def many.view(values: List<&1, BT.Target>, value: View) -> Q.Prepared & List<&2, E.AlignResult>:
  match value:
    case ReadyOwner{state}:
      batch(values, BatchState{state, Nil{}})
    case OtherOwner{prepared}:
      other(values, OtherState{prepared, Nil{}})

def many(prepared: Q.Prepared, batch: BT.Batch) -> Q.Prepared & List<&2, E.AlignResult>:
  BT.Batch{values, _, _, _} = batch
  many.view(values, view(prepared))
