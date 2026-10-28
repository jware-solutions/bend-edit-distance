import Base
import ../EdlibTypes.bend as E
import ./Sequence.bend as S
import ./BitVector.bend as V
import ./Profile.bend as P
import ./Workspace.bend as W
import ./DistanceDP.bend as DP

# Exact, unbanded final-row scores for every target prefix, including empty.
# Each pass owns both profile and workspace. No final-distance band is reused.
type Frontier is Type:
  Frontier{profile: P.Profile, workspace: W.Workspace, scores: List<U32>}

def scored(profile: P.Profile, scores: List<U32>, result: W.Workspace & U32) -> Frontier:
  (workspace, value) = result
  Frontier{profile, workspace, value <> scores}

def updated(padding: Nat, scores: List<U32>, state: W.Updated) -> Frontier:
  W.Updated{profile, workspace, _, _} = state
  scored(profile, scores, W.last_score(workspace, padding))

def scan(target: String, +padding: Nat, state: Frontier) -> List<U32>:
  match target state:
    case SNil{} Frontier{_, _, scores}:
      List.reverse(&1, U32, scores)
    case SCon{h, t} Frontier{profile, workspace, scores}:
      scan(t, padding, updated(padding, scores,
        W.column(profile, workspace, Char.to_u32(h), V.Carry{1, 0})))

type Args is Type:
  BitArgs{target: String, padding: Nat, state: Frontier}
  ScalarArgs{query: String, target: String, pairs: List<&2, E.EqualityPair>, columns: Nat}
  EmptyArgs{scores: List<U32>}

def prepare.supported(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>,
                        +length: Nat, compact: Bool) -> Args:
  match compact:
    case False{}:
      ScalarArgs{query, target, pairs, S.length(target)}
    case True{}:
      +count = V.ceil_div(length, 32n)
      BitArgs{target, Nat.sub(Nat.mul(count, 32n), length),
        Frontier{P.build(query, length, pairs), W.initialize(W.new(count), count), [U32.from_nat(length)]}}

def prepare(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>) -> Args:
  match query:
    case SNil{}:
      EmptyArgs{DP.initial_row(S.length(target), 0)}
    case _:
      prepare.supported(query, target, pairs, S.length(query),
        Bool.and(Bool.and(P.bytes(query), P.bytes(target)), P.byte_pairs(pairs)))

def run(args: Args) -> List<U32>:
  match args:
    case BitArgs{target, padding, state}:
      scan(target, padding, state)
    case ScalarArgs{query, target, pairs, columns}:
      DP.final_row(query, target, DP.initial_row(columns, 0), 1, pairs)
    case EmptyArgs{scores}:
      scores

def row(query: String, target: String, pairs: List<&2, E.EqualityPair>) -> List<U32>:
  run(prepare(query, target, pairs))
