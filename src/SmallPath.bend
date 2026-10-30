import Base
import ../EdlibTypes.bend as E
import ./PathList.bend as PL

# Exact complete paths within an edit bound. This frontier does not supply
# arbitrary midpoint scores; Frontier.bend retains that separate contract.
type Trail is Data:
  Start{matches: Nat}
  Step{operation: E.Operation, matches: Nat, previous: Trail}

type State is Data:
  Missing{}
  Reached{index: Nat, query: String, target: String, trail: Trail}

type Seed is Data:
  NoSeed{}
  Seed{index: Nat, query: String, target: String, operation: E.Operation, previous: Trail}

type Cursor is Data:
  Cursor{index: Nat, query: String, target: String, matches: Nat, active: Bool}

def extended(q: Char, qt: String, t: Char, tt: String, index: Nat, matches: Nat, same: Bool) -> Cursor:
  match same:
    case True{}:
      Cursor{1n+index, qt, tt, 1n+matches, True{}}
    case False{}:
      Cursor{index, SCon{q, qt}, SCon{t, tt}, matches, False{}}

def extend(fuel: Nat, +pairs: List<&2, E.EqualityPair>, cursor: Cursor) -> Cursor:
  match fuel cursor:
    case 0n _:
      cursor
    case _ Cursor{index, query, target, matches, False{}}:
      Cursor{index, query, target, matches, False{}}
    case 1n+p Cursor{index, SCon{+q, qt}, SCon{+t, tt}, matches, True{}}:
      extend(p, pairs, extended(q, qt, t, tt, index, matches, E.equal(pairs, q, t)))
    case _ _:
      cursor

def inserted(value: State) -> Seed:
  match value:
    case Reached{index, SCon{_, tail}, target, previous}:
      Seed{1n+index, tail, target, E.Insert{}, previous}
    case _:
      NoSeed{}

def deleted(value: State) -> Seed:
  match value:
    case Reached{index, query, SCon{_, tail}, previous}:
      Seed{index, query, tail, E.Delete{}, previous}
    case _:
      NoSeed{}

def substituted(value: State) -> Seed:
  match value:
    case Reached{index, SCon{_, qt}, SCon{_, tt}, previous}:
      Seed{1n+index, qt, tt, E.Mismatch{}, previous}
    case _:
      NoSeed{}

def selected(a: Seed, b: Seed, left: Bool) -> Seed:
  match left:
    case True{}:
      a
    case False{}:
      b

def farther(a: Seed, b: Seed) -> Seed:
  match a b:
    case NoSeed{} _:
      b
    case _ NoSeed{}:
      a
    case Seed{+ai, aq, at, ao, ap} Seed{+bi, bq, bt, bo, bp}:
      selected(Seed{ai, aq, at, ao, ap}, Seed{bi, bq, bt, bo, bp}, Nat.is_ge(ai, bi))

def completed(operation: E.Operation, previous: Trail, cursor: Cursor) -> State:
  Cursor{index, query, target, matches, _} = cursor
  Reached{index, query, target, Step{operation, matches, previous}}

def advance(fuel: Nat, pairs: List<&2, E.EqualityPair>, seed: Seed) -> State:
  match seed:
    case NoSeed{}:
      Missing{}
    case Seed{index, query, target, operation, previous}:
      completed(operation, previous, extend(fuel, pairs, Cursor{index, query, target, 0n, True{}}))

type Progress is Data:
  Progress{values: List<&2, State>, found: Maybe<&2, Trail>}

def record(value: State, values: List<&2, State>) -> Progress:
  match value:
    case Reached{_, SNil{}, SNil{}, trail}:
      Progress{values, Some{trail}}
    case _:
      Progress{value <> values, None{}}

type Row is Data:
  Row{before: State, current: State, remaining: List<&2, State>, progress: Progress}

def next(+pairs: List<&2, E.EqualityPair>, +match_fuel: Nat, a: State, +b: State,
           +c: State, remaining: List<&2, State>, values: List<&2, State>) -> Row:
  Row{b, c, remaining, record(advance(match_fuel, pairs,
    farther(inserted(a), farther(deleted(c), substituted(b)))), values)}

def row(fuel: Nat, +pairs: List<&2, E.EqualityPair>, +match_fuel: Nat, value: Row) -> Progress:
  match fuel value:
    case _ Row{_, _, _, Progress{values, Some{trail}}}:
      Progress{values, Some{trail}}
    case 0n Row{_, _, _, Progress{values, None{}}}:
      Progress{List.reverse(&2, State, values), None{}}
    case 1n+p Row{a, b, Nil{}, Progress{values, None{}}}:
      row(p, pairs, match_fuel, next(pairs, match_fuel, a, b, Missing{}, Nil{}, values))
    case 1n+p Row{a, b, c <> tail, Progress{values, None{}}}:
      row(p, pairs, match_fuel, next(pairs, match_fuel, a, b, c, tail, values))

type Search is Data:
  NotFound{}
  Found{cost: Nat, trail: Trail}

def rows(fuel: Nat, +pairs: List<&2, E.EqualityPair>, +match_fuel: Nat,
            +cost: Nat, progress: Progress) -> Search:
  match fuel progress:
    case _ Progress{_, Some{trail}}:
      Found{cost, trail}
    case 0n _:
      NotFound{}
    case 1n+p Progress{values, None{}}:
      +next_cost = {1n+cost : Nat}
      rows(p, pairs, match_fuel, next_cost, row(1n+Nat.mul(2n, next_cost), pairs, match_fuel,
        Row{Missing{}, Missing{}, values, Progress{Nil{}, None{}}}))

def initial(cursor: Cursor) -> State:
  Cursor{index, query, target, matches, _} = cursor
  Reached{index, query, target, Start{matches}}

# Every saved state has exhausted its free matching run. Each cost row
# depends on the preceding row; individual target columns are not forked.
def limit() -> Nat:
  16n

def search(+query: String, target: String, +pairs: List<&2, E.EqualityPair>, maximum: Nat) -> Search:
  +match_fuel = String.length(query)
  rows(maximum, pairs, match_fuel, 0n,
    record(initial(extend(match_fuel, pairs, Cursor{0n, query, target, 0n, True{}})), Nil{}))

def operations(trail: Trail, suffix: List<&2, E.Operation>) -> List<&2, E.Operation>:
  match trail:
    case Start{matches}:
      PL.repeat(matches, E.Match{}, suffix)
    case Step{operation, matches, previous}:
      operations(previous, operation <> PL.repeat(matches, E.Match{}, suffix))

def known.result(distance: Nat, result: Search) -> Maybe<&2, List<&2, E.Operation>>:
  match result:
    case NotFound{}:
      None{}
    case Found{cost, trail}:
      Bool.pick(Maybe<&2, List<&2, E.Operation>>, Nat.is_eq(distance, cost),
        Some{operations(trail, Nil{})}, None{})

def known(query: String, target: String, pairs: List<&2, E.EqualityPair>, +distance: Nat) -> Maybe<&2, List<&2, E.Operation>>:
  known.result(distance, search(query, target, pairs, distance))
