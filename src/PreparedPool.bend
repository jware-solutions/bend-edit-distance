import ./Word.bend as Word
import Base
import ../Prepared.bend as Q
import ../EdlibTypes.bend as E
import ./BitVector.bend as V
import ./Batch.bend as B
import ./Profile.bend as Profile
import ./Workspace.bend as W
import ./SearchKernel.bend as K

# Independently owned masks/workspaces are cloned once, before device execution.
# Cached owners move into ready execution plans without reading their buffers.
type Pool is Type:
  Pool{owners: List<Q.Prepared>, shards: Nat, length: Nat, budget: Nat}

type Cloning is Type:
  Cloning{owner: Q.Prepared, others: List<Q.Prepared>}

def clone.next(others: List<Q.Prepared>, result: Q.Prepared & Q.Prepared) -> Cloning:
  (owner, other) = result
  Cloning{owner, other <> others}

def clone(fuel: Nat, state: Cloning) -> List<Q.Prepared>:
  match fuel state:
    case 0n Cloning{owner, others}:
      owner <> others
    case 1n+p Cloning{owner, others}:
      clone(p, clone.next(others, Q.clone(owner)))

def prepared(maximum: Nat, result: Q.Prepared & Nat) -> Pool:
  (owner, bytes) = result
  Q.Prepared{query, +pairs, +length, profile, workspace} = owner
  +shared = Nat.add(Nat.mul(length, 16n), Nat.mul(List.length(&2, E.EqualityPair, pairs), 32n))
  +shared_budget = Nat.mul(shared, 2n)
  +per_owner = Nat.add(4096n, Nat.sub(bytes, shared))
  +limit = Nat.max(1n, Nat.min(maximum, Nat.div(Nat.sub(33554432n, shared_budget), per_owner)))
  +shards = Nat.pow(2n, U32.log2(U32.from_nat(Nat.min(4096n, limit))))
  Pool{clone(Nat.sub(shards, 1n), Cloning{Q.Prepared{query, pairs, length, profile, workspace}, Nil{}}),
    shards, length, Nat.add(shared_budget, Nat.mul(per_owner, shards))}

def prepare_with_max(maximum: Nat, query: String, pairs: List<&2, E.EqualityPair>) -> Pool:
  prepared(maximum, Q.retained_bytes(Q.prepare(query, pairs)))

def prepare(query: String, pairs: List<&2, E.EqualityPair>) -> Pool:
  prepare_with_max(1024n, query, pairs)

def retained(pool: Pool) -> Pool & Nat:
  Pool{owners, shards, length, +budget} = pool
  # Transport admission adds its own factor/allowance for CPU queries. Return
  # an equivalent payload so admission charges this already conservative pool.
  (Pool{owners, shards, length, budget}, Nat.div(Nat.sub(budget, 4096n), 2n))

type Target is Data:
  Target{index: Nat, sequence: String, length: Nat, work: F32}

def reindex(values: List<&2, Target>, +index: Nat) -> List<&2, Target>:
  match values:
    case Nil{}:
      Nil{}
    case Target{_, sequence, length, work} <> tail:
      Target{index, sequence, length, work} <> reindex(tail, 1n+index)

def target_work(+length: Nat, +columns: Nat, options: Q.Options) -> F32:
  match options:
    case Q.Options{E.NW{}, _, E.MaxDistance{maximum}, _}:
      Bool.pick(F32, Nat.is_gt(Nat.max(Nat.sub(length, columns), Nat.sub(columns, length)), maximum),
        1.0, F32.mul(F32.from_nat(1n+Word.blocks(length)), F32.from_nat(1n+columns)))
    case Q.Options{E.HW{}, E.Distance{}, _, _}:
      F32.mul(F32.from_nat(1n+Word.blocks(length)), F32.from_nat(1n+columns))
    case Q.Options{E.HW{}, _, _, _}:
      (F32.from_nat(1n+Word.blocks(length)) * F32.from_nat(1n+columns) * F32.from_nat(1n+columns) : F32)
    case _:
      F32.mul(F32.from_nat(1n+Word.blocks(length)), F32.from_nat(1n+columns))

def target.sized(index: Nat, +sequence: String, +length: Nat, query_length: Nat, options: Q.Options) -> Target:
  Target{index, sequence, length, target_work(query_length, length, options)}

def targets(values: List<&2, String>, +index: Nat, +length: Nat, +options: Q.Options) -> List<&2, Target>:
  match values:
    case Nil{}:
      Nil{}
    case +sequence <> tail:
      target.sized(index, sequence, String.length(sequence), length, options) <>
        targets(tail, 1n+index, length, options)

def heavier(a: Target, b: Target) -> Bool:
  Target{_, _, _, x} = a
  Target{_, _, _, y} = b
  F32.is_ge(x, y)

def same_work(values: List<&2, Target>, +work: F32) -> Bool:
  match values:
    case Nil{}:
      True{}
    case Target{_, _, _, value} <> tail:
      Bool.and(F32.is_eq(value, work), same_work(tail, work))

def homogeneous(values: List<&2, Target>) -> Bool:
  match values:
    case Nil{}:
      True{}
    case Target{_, _, _, +work} <> tail:
      same_work(tail, work)

type Group is Data:
  Group{room: Nat, work: F32, jobs: List<&2, Target>}

def group.add(group: Group, target: Target) -> Group:
  Group{room, work, jobs} = group
  Target{index, sequence, length, +cost} = target
  Group{Nat.sub(room, 1n), F32.add(work, cost), Target{index, sequence, length, cost} <> jobs}

def group.left(a: Group, b: Group) -> Bool:
  match a b:
    case Group{0n, _, _} _:
      False{}
    case _ Group{0n, _, _}:
      True{}
    case Group{_, x, _} Group{_, y, _}:
      F32.is_le(x, y)

def group.place(target: Target, a: Group, b: Group, left: Bool) -> Group & Group:
  match left:
    case True{}:
      (group.add(a, target), b)
    case False{}:
      (a, group.add(b, target))

def partition(values: List<&2, Target>, groups: Group & Group) -> Group & Group:
  match values:
    case Nil{}:
      groups
    case value <> tail:
      (+a, +b) = groups
      partition(tail, group.place(value, a, b, group.left(a, b)))

def owners.prepend(owner: Q.Prepared, parts: List<Q.Prepared> & List<Q.Prepared>) -> List<Q.Prepared> & List<Q.Prepared>:
  (before, after) = parts
  (owner <> before, after)

def owners.split(fuel: Nat, owners: List<Q.Prepared>) -> List<Q.Prepared> & List<Q.Prepared>:
  match fuel owners:
    case 0n _:
      (Nil{}, owners)
    case _ Nil{}:
      (Nil{}, Nil{})
    case 1n+p owner <> tail:
      owners.prepend(owner, owners.split(p, tail))

type Plan is Type:
  Leaf{owner: Q.Prepared, targets: List<&2, Target>}
  Fork{left: Plan, right: Plan}

def groups.jobs(groups: Group & Group) -> List<&2, Target> & List<&2, Target>:
  (Group{_, _, a}, Group{_, _, b}) = groups
  (List.reverse(&2, Target, a), List.reverse(&2, Target, b))

def split_jobs(+jobs: List<&2, Target>, +count: Nat, ordered: Bool) -> List<&2, Target> & List<&2, Target>:
  match ordered:
    case True{}:
      +half = Nat.div(count, 2n)
      (List.take(&2, Target, jobs, half), List.drop(&2, Target, jobs, half))
    case False{}:
      +half = Nat.div(count, 2n)
      groups.jobs(partition(jobs, (Group{half, 0.0, Nil{}}, Group{Nat.sub(count, half), 0.0, Nil{}})))

def branch.parts(parts: List<Q.Prepared> & List<Q.Prepared>, jobs: List<&2, Target> & List<&2, Target>,
                     next: List<Q.Prepared> -> List<Q.Prepared> -> List<&2, Target> -> List<&2, Target> -> Plan) -> Plan:
  (a, b) = parts
  (left, right) = jobs
  next(a, b, left, right)

def branch(fuel: Nat, owners: List<Q.Prepared>, +shards: Nat, jobs: List<&2, Target>,
               +count: Nat, +ordered: Bool) -> Plan:
  match fuel owners shards:
    case _ owner <> Nil{} _:
      Leaf{owner, jobs}
    case _ Nil{} _:
      # Preparation always provides an owner; this case only closes the type.
      Leaf{Q.prepare("", Nil{}), jobs}
    case 0n owner <> _ _:
      Leaf{owner, jobs}
    case _ owner <> _ 0n:
      Leaf{owner, jobs}
    case Succ{+p} _ _:
      +half = Nat.div(shards, 2n)
      branch.parts(owners.split(half, owners), split_jobs(jobs, count, ordered),
        a => b => left => right => Fork{
          branch(p, a, half, left, Nat.div(count, 2n), ordered),
          branch(p, b, Nat.sub(shards, half), right, Nat.sub(count, Nat.div(count, 2n)), ordered)})

type PoolReady is Type:
  PoolReady{plan: Plan, idle: List<Q.Prepared>, shards: Nat, length: Nat, budget: Nat, ordered: Bool}

def ready.owners(shards: Nat, length: Nat, budget: Nat, +active: Nat, jobs: List<&2, Target>,
                     count: Nat, +ordered: Bool, parts: List<Q.Prepared> & List<Q.Prepared>) -> PoolReady:
  (owners, idle) = parts
  PoolReady{branch(active, owners, active, jobs, count, ordered), idle, shards, length, budget, ordered}

def sorted_jobs(jobs: List<&2, Target>, ordered: Bool) -> List<&2, Target>:
  match ordered:
    case True{}:
      jobs
    case False{}:
      List.sort(~Target, ~heavier, jobs)

def ready.jobs(pool: Pool, +jobs: List<&2, Target>, +ordered: Bool) -> PoolReady:
  Pool{owners, +shards, length, budget} = pool
  +count = List.length(&2, Target, jobs)
  +active = Nat.min(shards, Nat.max(1n, count))
  ready.owners(shards, length, budget, active,
    sorted_jobs(jobs, ordered), count, ordered,
    owners.split(active, owners))

def ready.inspected(pool: Pool, +jobs: List<&2, Target>) -> PoolReady:
  ready.jobs(pool, jobs, homogeneous(jobs))

def ready(pool: Pool, values: List<&2, String>, options: Q.Options) -> PoolReady:
  Pool{owners, shards, +length, budget} = pool
  ready.inspected(Pool{owners, shards, length, budget}, targets(values, 0n, length, options))

type PoolDone is Type:
  PoolDone{owners: List<Q.Prepared>, results: List<&2, B.IndexedResult>}

type LeafState is Type:
  LeafState{owner: Q.Prepared, results: List<&2, B.IndexedResult>}

def leaf.updated(index: Nat, results: List<&2, B.IndexedResult>, value: Q.Prepared & E.AlignResult) -> LeafState:
  (owner, result) = value
  LeafState{owner, B.IndexedResult{index, result} <> results}

def leaf(values: List<&2, Target>, +options: Q.Options, +known_bytes: Bool, state: LeafState) -> PoolDone:
  match values state:
    case Nil{} LeafState{owner, results}:
      PoolDone{[owner], List.reverse(&2, B.IndexedResult, results)}
    case Target{index, target, length, _} <> tail LeafState{owner, results}:
      leaf(tail, options, known_bytes, leaf.updated(index, results, Q.align_sized_known(owner, target, options, length, known_bytes)))

def joined(a: PoolDone, b: PoolDone) -> PoolDone:
  PoolDone{ao, ar} = a
  PoolDone{bo, br} = b
  PoolDone{List.append(&1, Q.Prepared, ao, bo), List.append(&2, B.IndexedResult, ar, br)}

def execute(plan: Plan, +options: Q.Options, +known_bytes: Bool) -> PoolDone:
  match plan:
    case Leaf{owner, values}:
      leaf(values, options, known_bytes, LeafState{owner, Nil{}})
    case Fork{left, right}:
      a b = execute(left, options, known_bytes) execute(right, options, known_bytes)
      joined(a, b)

# Keep distance leaves statically fork-free. Expanding a generic alignment
# leaf during CPU frontier growth can execute its whole search on that row.
type DistanceState is Type:
  DistanceState{query: String, pairs: List<&2, E.EqualityPair>, length: Nat,
    profile: Profile.Profile, workspace: W.Workspace, results: List<&2, B.IndexedResult>}

def distance_result(columns: Nat, distance: E.EditDistance) -> E.AlignResult:
  match distance:
    case E.NotFound{}:
      E.not_found()
    case E.Found{score}:
      E.distance_result(score, E.end_coordinate(columns), True{})

def distance_updated(index: Nat, columns: Nat, query: String, pairs: List<&2, E.EqualityPair>, length: Nat,
                       results: List<&2, B.IndexedResult>, run: K.Run) -> DistanceState:
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = run
  DistanceState{query, pairs, length, profile, workspace,
    B.IndexedResult{index, distance_result(columns, distance)} <> results}

def distance_leaf(values: List<&2, Target>, +threshold: E.Threshold, state: DistanceState) -> PoolDone:
  match values state:
    case Nil{} DistanceState{query, pairs, length, profile, workspace, results}:
      PoolDone{[Q.Prepared{query, pairs, length, Some{profile}, workspace}],
        List.reverse(&2, B.IndexedResult, results)}
    case Target{index, SNil{}, _, _} <> tail DistanceState{query, pairs, +length, profile, workspace, results}:
      # Empty inputs retain their public threshold exception.
      distance_leaf(tail, threshold, DistanceState{query, pairs, length, profile, workspace,
        B.IndexedResult{index, E.distance_result(length, E.BeforeStart{}, True{})} <> results})
    case Target{index, target, +columns, _} <> tail DistanceState{query, pairs, +length, profile, workspace, results}:
      distance_leaf(tail, threshold, distance_updated(index, columns, query, pairs, length, results,
        K.search(target, profile, workspace, length, columns, threshold)))

def execute_distance(plan: Plan, +threshold: E.Threshold) -> PoolDone:
  match plan:
    case Leaf{Q.Prepared{query, pairs, length, Some{profile}, workspace}, values}:
      distance_leaf(values, threshold, DistanceState{query, pairs, length, profile, workspace, Nil{}})
    case Leaf{owner, values}:
      leaf(values, Q.Options{E.NW{}, E.Distance{}, threshold, E.Extended{}}, True{}, LeafState{owner, Nil{}})
    case Fork{Leaf{Q.Prepared{aq, ap, an, Some{am}, aw}, av}, Leaf{Q.Prepared{bq, bp, bn, Some{bm}, bw}, bv}}:
      # Direct leaf tasks let the pinned scheduler distribute both children
      # before entering their sequential column/carry loops.
      ast = {DistanceState{aq, ap, an, am, aw, Nil{}} : DistanceState}
      bst = {DistanceState{bq, bp, bn, bm, bw, Nil{}} : DistanceState}
      a b = distance_leaf(av, threshold, ast) distance_leaf(bv, threshold, bst)
      joined(a, b)
    case Fork{left, right}:
      a b = execute_distance(left, threshold) execute_distance(right, threshold)
      joined(a, b)

def execute_known(+known_bytes: Bool, plan: Plan, +options: Q.Options) -> PoolDone:
  match known_bytes options:
    case True{} Q.Options{E.NW{}, E.Distance{}, threshold, _}:
      execute_distance(plan, threshold)
    case _ _:
      execute(plan, options, known_bytes)

def ordered_results(values: List<&2, B.IndexedResult>, ordered: Bool) -> List<&2, E.AlignResult>:
  match ordered:
    case True{}:
      B.results(values)
    case False{}:
      B.ordered(values)

def finish(idle: List<Q.Prepared>, shards: Nat, length: Nat, budget: Nat, ordered: Bool, result: PoolDone) ->
           Pool & List<&2, E.AlignResult>:
  PoolDone{owners, +values} = result
  (Pool{List.append(&1, Q.Prepared, owners, idle), shards, length, budget},
    ordered_results(values, ordered))

def align_ready_known(ready: PoolReady, options: Q.Options, known_bytes: Bool) -> Pool & List<&2, E.AlignResult>:
  PoolReady{plan, idle, shards, length, budget, ordered} = ready
  finish(idle, shards, length, budget, ordered, execute_known(known_bytes, plan, options))

def align_ready(ready: PoolReady, options: Q.Options) -> Pool & List<&2, E.AlignResult>:
  align_ready_known(ready, options, False{})

def align_batch(pool: Pool, targets: List<&2, String>, +options: Q.Options) -> Pool & List<&2, E.AlignResult>:
  align_ready(ready(pool, targets, options), options)

def single_result(value: Pool & List<&2, E.AlignResult>) -> Pool & E.AlignResult:
  match value:
    case (pool, result <> _):
      (pool, result)
    case (pool, Nil{}):
      (pool, E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}})
