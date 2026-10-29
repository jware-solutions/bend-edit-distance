import Base
import ../EdlibTypes.bend as E
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/BitVector.bend as V
import ../src/Word.bend as Word
import ../src/Sequence.bend as S
import ../src/Transport.bend as T

def step(profile: P.Profile, workspace: W.Workspace, symbol: U32, reference: Bool) -> W.Updated:
  match reference:
    case False{}:
      W.column(profile, workspace, symbol, V.Carry{1, 0})
    case True{}:
      W.column_reference(profile, workspace, symbol, V.Carry{1, 0})

def scan(target: String, +reference: Bool, state: W.Updated) -> W.Updated:
  match target state:
    case SNil{} _:
      state
    case SCon{symbol, tail} W.Updated{profile, workspace, _, _}:
      scan(tail, reference, step(profile, workspace, Char.to_u32(symbol), reference))

def blocks.value(result: W.Workspace & V.Block, next: W.Workspace -> String) -> String:
  (workspace, V.Block{positive, negative, score}) = result
  U32.show(positive) ++ "," ++ U32.show(negative) ++ "," ++ U32.show(score) ++ ";" ++
    next(workspace)

def blocks(fuel: Nat, +index: U32, workspace: W.Workspace) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      blocks.value(W.get(workspace, index), next => blocks(p, U32.inc(index), next))

def show(state: W.Updated) -> String:
  W.Updated{_, W.Workspace{data, +capacity, +first, +last}, score, V.Carry{positive, negative}} = state
  U32.show(capacity) ++ ":" ++ U32.show(first) ++ ":" ++ U32.show(last) ++ ":" ++
    U32.show(score) ++ ":" ++ U32.show(positive) ++ ":" ++ U32.show(negative) ++ ":" ++
    blocks(U32.to_nat(capacity), 0, W.Workspace{data, capacity, first, last})

def drop_last(mode: E.Mode) -> Nat:
  match mode:
    case E.NW{}:
      0n
    case E.SHW{}:
      1n
    case E.HW{}:
      5n

def run_sized(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>,
                 +length: Nat, +count: Nat, +first: Nat, +last: Nat) -> IO(Unit):
  do IO<Unit>:
    IO.print(show(scan(target, False{}, W.Updated{P.build(query, length, pairs),
      W.bounds(W.initialize(W.new(count), count), U32.from_nat(first), U32.from_nat(last)), 0, V.Carry{1, 0}})))
    IO.print(show(scan(target, True{}, W.Updated{P.build(query, length, pairs),
      W.bounds(W.initialize(W.new(count), count), U32.from_nat(first), U32.from_nat(last)), 0, V.Carry{1, 0}})))

def run(job: E.AlignJob) -> IO(Unit):
  match job:
    case E.AlignJob{+query, target, E.AlignConfig{mode, _, E.MaxDistance{maximum}, pairs, _}}:
      +length = S.length(query)
      +count = Word.blocks(length)
      +last = Nat.sub(count, drop_last(mode))
      run_sized(query, target, pairs, length, count, Nat.min(maximum, last), last)
    case _:
      IO.die(Unit, 2, "Expected a finite first-block index")

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    run(job)
