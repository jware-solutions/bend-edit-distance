import Base
import ../Prepared.bend as Q
import ./PreparedPool.bend as P
import ./PreparedBytes.bend as Bytes
import ./ByteTarget.bend as BT
import ./Word.bend as Word
import ../EdlibTypes.bend as E

# Contiguous weighted partitions preserve order while moving each buffer into
# exactly one leaf. Complete plans precede all execution forks.
type Split is Type:
  Split{left: List<&1, BT.Target>, right: List<&1, BT.Target>, count: Nat, units: Nat}

type Splitting is Type:
  Splitting{before: List<&1, BT.Target>, count: Nat, units: Nat, done: Bool}

def split.add(value: BT.Target, state: Splitting, minimum: Nat, maximum: Nat, half: Nat) -> Splitting:
  BT.Target{bytes, +length} = value
  Splitting{before, count, units, _} = state
  +next_count = {1n+count : Nat}
  +next_units = Nat.add(units, 1n+length)
  Splitting{BT.Target{bytes, length} <> before, next_count, next_units,
    Bool.or(Nat.is_ge(next_count, maximum), Bool.and(Nat.is_ge(next_count, minimum), Nat.is_ge(next_units, half)))}

def split(fuel: Nat, values: List<&1, BT.Target>, +minimum: Nat, +maximum: Nat,
              +half: Nat, state: Splitting) -> Split:
  match fuel values state:
    case _ _ Splitting{before, count, units, True{}}:
      Split{List.reverse(&1, BT.Target, before), values, count, units}
    case 0n _ Splitting{before, count, units, _}:
      Split{List.reverse(&1, BT.Target, before), values, count, units}
    case _ Nil{} Splitting{before, count, units, _}:
      Split{List.reverse(&1, BT.Target, before), Nil{}, count, units}
    case 1n+p value <> tail _:
      split(p, tail, minimum, maximum, half, split.add(value, state, minimum, maximum, half))

type Pieces is Type:
  Pieces{left: List<&1, BT.Target>, right: List<&1, BT.Target>}

def split.count(fuel: Nat, values: List<&1, BT.Target>, before: List<&1, BT.Target>) -> Pieces:
  match fuel values:
    case 0n _:
      Pieces{List.reverse(&1, BT.Target, before), values}
    case _ Nil{}:
      Pieces{List.reverse(&1, BT.Target, before), Nil{}}
    case 1n+p value <> tail:
      split.count(p, tail, value <> before)

def split.count.filled(count: Nat, units: Nat, value: Pieces) -> Split:
  Pieces{left, right} = value
  Split{left, right, count, units}

def split.jobs(values: List<&1, BT.Target>, +count: Nat, +units: Nat, +shards: Nat,
                   +half: Nat, uniform: Bool) -> Split:
  match uniform:
    case True{}:
      +moved = Nat.div(count, 2n)
      split.count.filled(moved, Nat.mul(moved, Nat.div(units, count)), split.count(moved, values, Nil{}))
    case False{}:
      split(count, values, half, Nat.sub(count, Nat.sub(shards, half)), Nat.div(units, 2n),
        Splitting{Nil{}, 0n, 0n, False{}})

type Plan is Type:
  Leaf{owner: Bytes.View, targets: List<&1, BT.Target>}
  Fork{left: Plan, right: Plan}

def branch.parts(parts: List<Q.Prepared> & List<Q.Prepared>, jobs: Split,
                     next: List<Q.Prepared> -> List<Q.Prepared> -> List<&1, BT.Target> -> List<&1, BT.Target> -> Nat -> Nat -> Plan) -> Plan:
  (a, b) = parts
  Split{left, right, count, units} = jobs
  next(a, b, left, right, count, units)

def branch(fuel: Nat, owners: List<Q.Prepared>, +shards: Nat, values: List<&1, BT.Target>,
               +count: Nat, +units: Nat, +uniform: Bool) -> Plan:
  match fuel owners shards:
    case _ owner <> Nil{} _:
      Leaf{Bytes.view(owner), values}
    case _ Nil{} _:
      Leaf{Bytes.view(Q.prepare("", Nil{})), values}
    case 0n owner <> _ _:
      Leaf{Bytes.view(owner), values}
    case _ owner <> _ 0n:
      Leaf{Bytes.view(owner), values}
    case Succ{+p} _ _:
      +half = Nat.div(shards, 2n)
      branch.parts(P.owners.split(half, owners), split.jobs(values, count, units, shards, half, uniform),
        a => b => left => right => +moved => +work => Fork{
          branch(p, a, half, left, moved, work, uniform),
          branch(p, b, Nat.sub(shards, half), right, Nat.sub(count, moved), Nat.sub(units, work), uniform)})

type ByteDone is Type:
  ByteDone{owners: List<Q.Prepared>, results: List<&2, E.AlignResult>}

def leaf(value: Q.Prepared & List<&2, E.AlignResult>) -> ByteDone:
  (owner, results) = value
  ByteDone{[owner], results}

def joined(a: ByteDone, b: ByteDone) -> ByteDone:
  ByteDone{ao, ar} = a
  ByteDone{bo, br} = b
  ByteDone{List.append(&1, Q.Prepared, ao, bo), List.append(&2, E.AlignResult, ar, br)}

def execute(plan: Plan) -> ByteDone:
  match plan:
    case Leaf{Bytes.ReadyOwner{state}, values}:
      leaf(Bytes.batch(values, Bytes.BatchState{state, Nil{}}))
    case Leaf{Bytes.OtherOwner{owner}, values}:
      leaf(Bytes.other(values, Bytes.OtherState{owner, Nil{}}))
    case Fork{Leaf{Bytes.ReadyOwner{a}, av}, Leaf{Bytes.ReadyOwner{b}, bv}}:
      ast = {Bytes.BatchState{a, Nil{}} : Bytes.BatchState}
      bst = {Bytes.BatchState{b, Nil{}} : Bytes.BatchState}
      left right = Bytes.batch(av, ast) Bytes.batch(bv, bst)
      joined(leaf(left), leaf(right))
    case Fork{left, right}:
      a b = execute(left) execute(right)
      joined(a, b)

def finish(idle: List<Q.Prepared>, shards: Nat, length: Nat, budget: Nat, value: ByteDone) -> P.Pool & List<&2, E.AlignResult>:
  ByteDone{owners, results} = value
  (P.Pool{List.append(&1, Q.Prepared, owners, idle), shards, length, budget}, results)

def ready(shards: Nat, length: Nat, budget: Nat, +active: Nat, values: List<&1, BT.Target>,
              count: Nat, units: Nat, uniform: Bool, parts: List<Q.Prepared> & List<Q.Prepared>) -> P.Pool & List<&2, E.AlignResult>:
  (owners, idle) = parts
  plan = {branch(active, owners, active, values, count, units, uniform) : Plan}
  finish(idle, shards, length, budget, execute(plan))

# Weighted byte work includes fixed result/ownership cost. Small leaves keep
# one owner; the other cached shards remain idle until a larger batch.
def serial_cutoff(+length: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_gt(length, Nat.mul(Word.width(), 3n)),
    Nat.is_le(length, Bytes.maximum_query())), 32768n, 65536n)

def active_owners(+shards: Nat, +count: Nat, units: Nat, +length: Nat) -> Nat:
  +columns = Nat.sub(units, count)
  +work = Nat.add(Nat.mul(columns, Word.blocks(length)), Nat.mul(count, 32n))
  Bool.pick(Nat, Bool.or(Nat.is_eq(columns, 0n), Nat.is_lt(work, serial_cutoff(length))),
    1n, Nat.min(shards, Nat.max(1n, count)))

def many(pool: P.Pool, batch: BT.Batch) -> P.Pool & List<&2, E.AlignResult>:
  P.Pool{owners, +shards, +length, budget} = pool
  BT.Batch{values, +count, +units, uniform} = batch
  +active = active_owners(shards, count, units, length)
  ready(shards, length, budget, active, values, count, units, U32.is_ne(uniform, 0), P.owners.split(active, owners))

def single(pool: P.Pool, target: BT.Target) -> P.Pool & E.AlignResult:
  BT.Target{bytes, +length} = target
  P.single_result(many(pool, BT.Batch{[BT.Target{bytes, length}], 1n, 1n+length, 1}))
