import Base
import ../EdlibTypes.bend as E
import ./BitVector.bend as V
import ./Profile.bend as P
import ./Workspace.bend as W
import ./Alignment.bend as A

type Stats is Data:
  Stats{distance: E.EditDistance, blocks: Nat, columns: Nat, attempts: Nat}

type Run is Type:
  Run{profile: P.Profile, workspace: W.Workspace, stats: Stats}

type Step is Type:
  Step{profile: P.Profile, workspace: W.Workspace, maximum: Nat, work: Nat}

type Trim is Type:
  Trim{workspace: W.Workspace, done: Bool}

def keep_last(+score: Nat, bottom: Nat, +maximum: Nat,
                length: Nat, target_length: Nat, column: Nat) -> Bool:
  Bool.and(Nat.is_lt(score, Nat.add(maximum, 32n)),
    Nat.is_le(Nat.add(Nat.add(bottom, score), target_length),
      Nat.add(Nat.add(Nat.add(maximum, length), column), 63n)))

def keep_first(+score: Nat, bottom: Nat, +maximum: Nat,
                 length: Nat, target_length: Nat, column: Nat) -> Bool:
  Bool.and(Nat.is_lt(score, Nat.add(maximum, 32n)),
    Nat.is_ge(Nat.add(Nat.add(bottom, maximum), target_length),
      Nat.add(Nat.add(score, length), column)))

def trim_last.choose(workspace: W.Workspace, keep: Bool) -> Trim:
  match workspace keep:
    case _ True{}:
      Trim{workspace, True{}}
    case W.Workspace{data, capacity, first, last} False{}:
      Trim{W.Workspace{data, capacity, first, U32.sub(last, 1)}, False{}}

def trim_last.score(bottom: Nat, maximum: Nat, length: Nat, target_length: Nat,
                      column: Nat, result: W.Workspace & U32) -> Trim:
  (workspace, score) = result
  trim_last.choose(workspace, keep_last(U32.to_nat(score), bottom, maximum, length, target_length, column))

def trim_last(fuel: Nat, +maximum: Nat, +length: Nat, +target_length: Nat,
                +column: Nat, state: Trim) -> W.Workspace:
  match fuel state:
    case 0n Trim{workspace, _}:
      workspace
    case _ Trim{workspace, True{}}:
      workspace
    case 1n+p Trim{W.Workspace{data, capacity, first, +last}, False{}}:
      trim_last(p, maximum, length, target_length, column,
        trim_last.score(U32.to_nat(U32.shln(last, 5n)), maximum, length, target_length, column,
          W.score(W.Workspace{data, capacity, first, last}, U32.sub(last, 1))))

def trim_first.choose(workspace: W.Workspace, keep: Bool) -> Trim:
  match workspace keep:
    case _ True{}:
      Trim{workspace, True{}}
    case W.Workspace{data, capacity, first, last} False{}:
      Trim{W.Workspace{data, capacity, U32.inc(first), last}, False{}}

def trim_first.score(bottom: Nat, maximum: Nat, length: Nat, target_length: Nat,
                       column: Nat, result: W.Workspace & U32) -> Trim:
  (workspace, score) = result
  trim_first.choose(workspace, keep_first(U32.to_nat(score), bottom, maximum, length, target_length, column))

def trim_first(fuel: Nat, +maximum: Nat, +length: Nat, +target_length: Nat,
                 +column: Nat, state: Trim) -> W.Workspace:
  match fuel state:
    case 0n Trim{workspace, _}:
      workspace
    case _ Trim{workspace, True{}}:
      workspace
    case 1n+p Trim{W.Workspace{data, capacity, +first, last}, False{}}:
      trim_first(p, maximum, length, target_length, column,
        trim_first.score(U32.to_nat(U32.shln(U32.inc(first), 5n)), maximum, length, target_length, column,
          W.score(W.Workspace{data, capacity, first, last}, first)))

def reduce.first(workspace: W.Workspace, maximum: Nat, length: Nat,
                   target_length: Nat, column: Nat) -> W.Workspace:
  W.Workspace{data, capacity, +first, +last} = workspace
  trim_first(U32.to_nat(U32.sub(last, first)), maximum, length, target_length, column,
    Trim{W.Workspace{data, capacity, first, last}, False{}})

def reduce(profile: P.Profile, workspace: W.Workspace, +maximum: Nat, +length: Nat,
              +target_length: Nat, +column: Nat, work: Nat) -> Step:
  W.Workspace{data, capacity, +first, +last} = workspace
  Step{profile, reduce.first(trim_last(U32.to_nat(U32.sub(last, first)), maximum, length,
    target_length, column, Trim{W.Workspace{data, capacity, first, last}, False{}}),
      maximum, length, target_length, column), maximum, work}

def expand.updated(maximum: Nat, length: Nat, target_length: Nat, column: Nat,
                      work: Nat, state: W.Updated) -> Step:
  W.Updated{profile, workspace, _, _} = state
  reduce(profile, workspace, maximum, length, target_length, column, 1n+work)

def expand.row(workspace: W.Workspace, +index: U32, previous: U32, carry: V.Carry,
                 maximum: Nat, length: Nat, target_length: Nat, column: Nat, work: Nat,
                 result: P.Profile & U32) -> Step:
  (profile, row) = result
  expand.updated(maximum, length, target_length, column, work,
    W.update(profile, W.put(workspace, index, V.Block{4294967295, 0, previous}), row, index, carry))

def expand(state: W.Updated, symbol: U32, +maximum: Nat, +length: Nat,
              +target_length: Nat, +column: Nat, work: Nat, expand: Bool) -> Step:
  match state expand:
    case W.Updated{profile, W.Workspace{data, +capacity, first, +last},
                    +score, V.Carry{+positive, +negative}} True{}:
      expand.row(W.Workspace{data, capacity, first, U32.inc(last)}, last,
        U32.add(U32.sub(U32.add(score, negative), positive), 32), V.Carry{positive, negative},
        maximum, length, target_length, column, work, P.row(profile, symbol))
    case W.Updated{profile, workspace, _, _} False{}:
      reduce(profile, workspace, maximum, length, target_length, column, work)

def step.updated(symbol: U32, +length: Nat, +target_length: Nat, +column: Nat,
                    maximum: Nat, padding: Nat, state: W.Updated) -> Step:
  W.Updated{profile, W.Workspace{data, +capacity, +first, +last}, +score, carry} = state
  +bottom = U32.to_nat(U32.shln(last, 5n))
  +k = Nat.min(maximum, Nat.add(U32.to_nat(score),
    Nat.add(Nat.max(Nat.sub(target_length, column), Nat.sub(length, bottom)),
      Bool.pick(Nat, Nat.is_ge(bottom, length), padding, 0n))))
  expand(W.Updated{profile, W.Workspace{data, capacity, first, last}, score, carry}, symbol,
    k, length, target_length, column, U32.to_nat(U32.sub(last, first)),
    Bool.and(U32.is_lt(last, capacity), Nat.is_le(Nat.add(Nat.add(bottom, U32.to_nat(score)), target_length),
      Nat.add(Nat.add(Nat.add(k, length), column), 62n))))

def finish.score(profile: P.Profile, maximum: Nat, blocks: Nat, columns: Nat,
                    result: W.Workspace & U32) -> Run:
  (workspace, +score) = result
  Run{profile, workspace, Stats{Bool.pick(E.EditDistance, Nat.is_le(U32.to_nat(score), maximum),
    E.Found{U32.to_nat(score)}, E.NotFound{}), blocks, columns, 1n}}

def finish(profile: P.Profile, workspace: W.Workspace, maximum: Nat, padding: Nat,
              blocks: Nat, columns: Nat, complete: Bool) -> Run:
  match complete:
    case True{}:
      finish.score(profile, maximum, blocks, columns, W.last_score(workspace, padding))
    case False{}:
      Run{profile, workspace, Stats{E.NotFound{}, blocks, columns, 1n}}

type ColumnReady is Type:
  ColumnReady{profile: P.Profile, workspace: W.Workspace, maximum: Nat, work: Nat, empty: Bool}

def ready(state: Step) -> ColumnReady:
  Step{profile, W.Workspace{data, capacity, +first, +last}, maximum, work} = state
  ColumnReady{profile, W.Workspace{data, capacity, first, last}, maximum, work, U32.is_eq(first, last)}

def nw(target: String, +length: Nat, +target_length: Nat, +padding: Nat,
          +column: Nat, blocks: Nat, state: ColumnReady) -> Run:
  match target state:
    case _ ColumnReady{profile, workspace, _, work, True{}}:
      Run{profile, workspace, Stats{E.NotFound{}, Nat.add(blocks, work), column, 1n}}
    case SNil{} ColumnReady{profile, W.Workspace{data, +capacity, first, +last}, maximum, work, False{}}:
      finish(profile, W.Workspace{data, capacity, first, last}, maximum, padding,
        Nat.add(blocks, work), column, U32.is_eq(last, capacity))
    case SCon{h, t} ColumnReady{profile, workspace, maximum, work, False{}}:
      +symbol = Char.to_u32(h)
      nw(t, length, target_length, padding, 1n+column, Nat.add(blocks, work),
        ready(step.updated(symbol, length, target_length, 1n+column, maximum, padding,
          W.column(profile, workspace, symbol, V.Carry{1, 0}))))

def initial_count(+length: Nat, +target_length: Nat, +maximum: Nat) -> Nat:
  Nat.min(V.ceil_div(length, 32n),
    V.ceil_div(1n+Nat.min(maximum, Nat.div(Nat.sub(Nat.add(maximum, length), target_length), 2n)), 32n))

def attempt(target: String, profile: P.Profile, workspace: W.Workspace,
               +length: Nat, +target_length: Nat, +maximum: Nat, padding: Nat) -> Run:
  nw(target, length, target_length, padding, 0n, 0n,
    ready(Step{profile, W.initialize(workspace, initial_count(length, target_length, maximum)), maximum, 0n}))

def accumulated(previous: Stats, result: Run) -> Run:
  Stats{_, blocks, columns, attempts} = previous
  Run{profile, workspace, Stats{distance, work, consumed, fresh}} = result
  Run{profile, workspace, Stats{distance, Nat.add(blocks, work), Nat.add(columns, consumed), Nat.add(attempts, fresh)}}

def adaptive(fuel: Nat, +target: String, +length: Nat, +target_length: Nat,
                +maximum: Nat, +padding: Nat, result: Run) -> Run:
  match fuel result:
    case _ Run{profile, workspace, Stats{E.Found{value}, blocks, columns, attempts}}:
      Run{profile, workspace, Stats{E.Found{value}, blocks, columns, attempts}}
    case 0n _:
      result
    case 1n+p Run{profile, workspace, stats}:
      adaptive(p, target, length, target_length, Nat.min(Nat.max(length, target_length), Nat.mul(maximum, 2n)), padding,
        accumulated(stats, attempt(target, profile, workspace, length, target_length, maximum, padding)))

def finite(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat,
              +target_length: Nat, +maximum: Nat, rejected: Bool) -> Run:
  match rejected:
    case True{}:
      Run{profile, workspace, Stats{E.NotFound{}, 0n, 0n, 0n}}
    case False{}:
      attempt(target, profile, workspace, length, target_length, Nat.min(maximum, Nat.max(length, target_length)),
        Nat.sub(Nat.mul(V.ceil_div(length, 32n), 32n), length))

def search(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat,
              +target_length: Nat, threshold: E.Threshold) -> Run:
  match threshold:
    case E.MaxDistance{+maximum}:
      finite(target, profile, workspace, length, target_length, maximum,
        Nat.is_lt(maximum, Nat.max(Nat.sub(length, target_length), Nat.sub(target_length, length))))
    case E.Unlimited{}:
      adaptive(1n+Nat.max(length, target_length), target, length, target_length,
        Nat.min(Nat.max(length, target_length), Nat.max(32n, Nat.max(Nat.sub(target_length, length), Nat.sub(length, target_length)))),
        Nat.sub(Nat.mul(V.ceil_div(length, 32n), 32n), length),
        Run{profile, workspace, Stats{E.NotFound{}, 0n, 0n, 0n}})

type BestRun is Type:
  BestRun{profile: P.Profile, workspace: W.Workspace, best: A.Best, empty: Bool}

def is_hw(mode: E.Mode) -> Bool:
  match mode:
    case E.HW{}:
      True{}
    case _:
      False{}

def trim_semi.score(+mode: E.Mode, maximum: Nat, index: U32, result: W.Workspace & U32) -> Trim:
  (workspace, score) = result
  trim_last.choose(workspace, Bool.or(
    Bool.and(is_hw(mode), U32.is_eq(index, 0)), Nat.is_lt(U32.to_nat(score), Nat.add(maximum, 32n))))

def trim_semi(fuel: Nat, +mode: E.Mode, +maximum: Nat, state: Trim) -> W.Workspace:
  match fuel state:
    case 0n Trim{workspace, _}:
      workspace
    case _ Trim{workspace, True{}}:
      workspace
    case 1n+p Trim{W.Workspace{data, capacity, first, +last}, False{}}:
      trim_semi(p, mode, maximum, trim_semi.score(mode, maximum, U32.sub(last, 1),
        W.score(W.Workspace{data, capacity, first, last}, U32.sub(last, 1))))

def semi_reduce(mode: E.Mode, maximum: Nat, state: W.Updated) -> W.Updated:
  W.Updated{profile, W.Workspace{data, capacity, +first, +last}, score, carry} = state
  W.Updated{profile, trim_semi(U32.to_nat(U32.sub(last, first)), mode, maximum,
    Trim{W.Workspace{data, capacity, first, last}, False{}}), score, carry}

def semi_expand.choose(profile: P.Profile, workspace: W.Workspace, +last: U32,
                          +previous: U32, +eq: U32, +carry: V.Carry,
                          mode: E.Mode, maximum: Nat, expand: Bool) -> W.Updated:
  match workspace expand:
    case W.Workspace{data, capacity, first, _} True{}:
      semi_reduce(mode, maximum, W.update.calculated(profile,
        W.Workspace{data, capacity, first, U32.inc(last)}, last,
        V.calculate_block(V.Block{4294967295, 0, U32.add(previous, 32)}, eq, carry)))
    case _ False{}:
      semi_reduce(mode, maximum, W.Updated{profile, workspace, 0, carry})

def semi_expand.mask(workspace: W.Workspace, last: U32, +score: U32,
                         carry: V.Carry, mode: E.Mode, +maximum: Nat,
                         result: P.Profile & U32) -> W.Updated:
  V.Carry{+positive, +negative} = carry
  (profile, eq0) = result
  +eq = {eq0 : U32}
  +previous = U32.sub(U32.add(score, negative), positive)
  semi_expand.choose(profile, workspace, last, previous, eq, V.Carry{positive, negative}, mode, maximum,
    Bool.and(Nat.is_le(U32.to_nat(previous), maximum),
      Bool.or(U32.is_ne(U32.and(eq, 1), 0), U32.is_ne(negative, 0))))

def semi_expand.row(workspace: W.Workspace, +last: U32, score: U32,
                        carry: V.Carry, mode: E.Mode, maximum: Nat,
                        result: P.Profile & U32) -> W.Updated:
  (profile, row) = result
  semi_expand.mask(workspace, last, score, carry, mode, maximum, P.mask(profile, row, last))

def semi_expand(symbol: U32, mode: E.Mode, maximum: Nat, state: W.Updated,
                   room: Bool) -> W.Updated:
  match state room:
    case W.Updated{profile, W.Workspace{data, capacity, first, +last}, score, carry} True{}:
      semi_expand.row(W.Workspace{data, capacity, first, last}, last, score, carry,
        mode, maximum, P.row(profile, symbol))
    case _ False{}:
      semi_reduce(mode, maximum, state)

def semi_step(symbol: U32, mode: E.Mode, maximum: Nat, state: W.Updated) -> W.Updated:
  W.Updated{profile, W.Workspace{data, +capacity, first, +last}, score, carry} = state
  semi_expand(symbol, mode, maximum,
    W.Updated{profile, W.Workspace{data, capacity, first, last}, score, carry}, U32.is_lt(last, capacity))

def best_ready(profile: P.Profile, workspace: W.Workspace, best: A.Best) -> BestRun:
  W.Workspace{data, capacity, +first, +last} = workspace
  BestRun{profile, W.Workspace{data, capacity, first, last}, best, U32.is_eq(first, last)}

def semi_endpoint.score(profile: P.Profile, column: Nat, +best: A.Best,
                           result: W.Workspace & U32) -> BestRun:
  A.Best{old, _} = best
  (workspace, score0) = result
  +score = {score0 : U32}
  best_ready(profile, workspace,
    A.update_best(best, score, A.Location{E.Position{column}, 0n}, U32.cmp(score, old)))

def semi_endpoint.choose(profile: P.Profile, workspace: W.Workspace, padding: Nat,
                            column: Nat, best: A.Best, complete: Bool) -> BestRun:
  match complete:
    case True{}:
      semi_endpoint.score(profile, column, best, W.last_score(workspace, padding))
    case False{}:
      best_ready(profile, workspace, best)

def semi_endpoint(padding: Nat, column: Nat, best: A.Best, state: W.Updated) -> BestRun:
  W.Updated{profile, W.Workspace{data, +capacity, +first, +last}, _, _} = state
  semi_endpoint.choose(profile, W.Workspace{data, capacity, first, last}, padding, column, best,
    Bool.and(U32.is_lt(first, last), U32.is_eq(last, capacity)))

def semi_carry(mode: E.Mode) -> V.Carry:
  match mode:
    case E.HW{}:
      V.Carry{0, 0}
    case _:
      V.Carry{1, 0}

def semi(target: String, +mode: E.Mode, +padding: Nat, +column: Nat, +maximum: Nat,
            state: BestRun) -> BestRun:
  match target state:
    case _ BestRun{profile, workspace, best, True{}}:
      BestRun{profile, workspace, A.ordered(best), True{}}
    case SNil{} BestRun{profile, workspace, best, empty}:
      BestRun{profile, workspace, A.ordered(best), empty}
    case SCon{h, t} BestRun{profile, workspace, A.Best{+score, locations}, _}:
      best = {A.Best{score, locations} : A.Best}
      +k = Nat.min(maximum, U32.to_nat(score))
      +symbol = Char.to_u32(h)
      semi(t, mode, padding, 1n+column, k,
        semi_endpoint(padding, column, best,
          semi_step(symbol, mode, k, W.column(profile, workspace, symbol, semi_carry(mode)))))

def initial_best(+length: Nat, before: Bool) -> A.Best:
  match before:
    case True{}:
      A.Best{U32.from_nat(length), [A.Location{E.BeforeStart{}, 0n}]}
    case False{}:
      A.Best{4294967295, Nil{}}

def best(target: String, profile: P.Profile, workspace: W.Workspace,
            +length: Nat, +maximum: Nat, mode: E.Mode) -> BestRun:
  +count = V.ceil_div(length, 32n)
  semi(target, mode, Nat.sub(Nat.mul(count, 32n), length), 0n, maximum,
    best_ready(profile, W.initialize(workspace, Nat.min(count, V.ceil_div(1n+maximum, 32n))),
      initial_best(length, Nat.is_ne(Nat.mod(length, 64n), 0n))))
