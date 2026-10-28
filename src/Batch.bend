import ./Profile.bend as P
import ./BitVector.bend as V
import Base
import ../EdlibTypes.bend as E
import ./Myers.bend as M

type WeightedJob is Data:
  WeightedJob{index: Nat, work: F32, query_length: Nat, target_length: Nat, job: E.AlignJob}

type Group is Data:
  Group{room: Nat, work: F32, jobs: List<&2, WeightedJob>}

# Build the entire plan before entering the alignment fork tree. Recursive
# argument preparation in a parallel call can drain the native frontier.
type Plan is Type:
  Empty{}
  Leaf{index: Nat, job: E.AlignJob}
  SizedLeaf{index: Nat, query_length: Nat, target_length: Nat, job: E.AlignJob}
  Ordered{plan: Plan}
  Fork{left: Plan, right: Plan}
  Serial{jobs: List<&2, WeightedJob>}

type IndexedResult is Data:
  IndexedResult{index: Nat, result: E.AlignResult}

def axes(mode: E.Mode, +qn: Nat, +tn: Nat) -> Nat & Nat:
  match mode:
    case E.NW{}:
      (Nat.min(qn, tn), Nat.max(qn, tn))
    case _:
      (qn, tn)

def extra_work(mode: E.Mode, task: E.Task, +q: F32, +t: F32,
               +blocks: F32, pairs: F32) -> F32:
  match mode task:
    case _ E.Distance{}:
      0.0
    case E.HW{} E.Path{}:
      (blocks * t * t + q * t * pairs : F32)
    case E.HW{} _:
      (blocks * t * t : F32)
    case _ E.Path{}:
      (q * t * pairs : F32)
    case _ _:
      0.0

def estimate_axes(+mode: E.Mode, task: E.Task, pairs: List<&2, E.EqualityPair>,
                  sizes: Nat & Nat) -> F32:
  (+length, columns) = sizes
  +l = F32.from_nat(length)
  +c = F32.from_nat(columns)
  +blocks = F32.from_nat(V.ceil_div(length, 32n))
  +p = (1.0 + F32.from_nat(List.length(&2, E.EqualityPair, pairs)) : F32)
  (257.0 + l + c + l * p + F32.min(256.0, l) * blocks + blocks * c +
    extra_work(mode, task, l, c, blocks, p) : F32)

# Scheduling estimates compact profile preparation, full Myers columns,
# worst-case HW start searches and PATH DP; similarity remains unknown.
# F32 avoids wrapping a U32 product or allocating a quadratic unary Nat.
# Bands, retries, similarity and the selected interval can change actual work.
def estimate_nw(+q: Nat, +t: Nat, task: E.Task, pairs: List<&2, E.EqualityPair>, rejected: Bool) -> F32:
  match rejected:
    case True{}:
      1.0
    case False{}:
      estimate_axes(E.NW{}, task, pairs, axes(E.NW{}, q, t))

def estimate_sizes(qn: Nat, tn: Nat, config: E.AlignConfig) -> F32:
  match qn tn config:
    case 0n _ _:
      1.0
    case _ 0n _:
      1.0
    case +q +t E.AlignConfig{E.NW{}, task, E.MaxDistance{maximum}, pairs, _}:
      estimate_nw(q, t, task, pairs, Nat.is_gt(Nat.max(Nat.sub(q, t), Nat.sub(t, q)), maximum))
    case +q +t E.AlignConfig{+mode, task, _, pairs, _}:
      estimate_axes(mode, task, pairs, axes(mode, q, t))

def estimate(+job: E.AlignJob) -> F32:
  E.AlignJob{query, target, config} = job
  # Scans are sequential here; pairs of arbitrary lengths need not balance.
  estimate_sizes(String.length(query), String.length(target), config)

def indexed.job(index: Nat, +job: E.AlignJob, +qn: Nat, +tn: Nat) -> WeightedJob:
  E.AlignJob{_, _, config} = job
  WeightedJob{index, estimate_sizes(qn, tn, config), qn, tn, job}

def indexed(jobs: List<&2, E.AlignJob>, +index: Nat) -> List<&2, WeightedJob>:
  match jobs:
    case Nil{}:
      Nil{}
    case +job <> tail:
      E.AlignJob{query, target, _} = job
      indexed.job(index, job, String.length(query), String.length(target)) <> indexed(tail, 1n+index)

def heavier(first: WeightedJob, second: WeightedJob) -> Bool:
  WeightedJob{_, a, _, _, _} = first
  WeightedJob{_, b, _, _, _} = second
  F32.is_ge(a, b)

def add(group: Group, job: WeightedJob) -> Group:
  Group{room, work, jobs} = group
  WeightedJob{index, +cost, qn, tn, value} = job
  Group{Nat.sub(room, 1n), F32.add(work, cost), WeightedJob{index, cost, qn, tn, value} <> jobs}

def choose(left: Group, right: Group) -> Bool:
  match left right:
    case Group{0n, _, _} _:
      False{}
    case _ Group{0n, _, _}:
      True{}
    case Group{_, a, _} Group{_, b, _}:
      F32.is_le(a, b)

def place(job: WeightedJob, left: Group, right: Group, use_left: Bool) -> Group & Group:
  match use_left:
    case True{}:
      (add(left, job), right)
    case False{}:
      (left, add(right, job))

# Largest estimated jobs go to the lighter branch. Capacity bounds keep both
# child counts within ceil(n/2), including zero/rounded/equal work estimates.
def partition(jobs: List<&2, WeightedJob>, groups: Group & Group) -> Group & Group:
  match jobs:
    case Nil{}:
      groups
    case job <> tail:
      (+left, +right) = groups
      partition(tail, place(job, left, right, choose(left, right)))

def group_jobs(group: Group) -> List<&2, WeightedJob>:
  Group{_, _, jobs} = group
  List.reverse(&2, WeightedJob, jobs)

def plan_step(groups: Group & Group,
              next: List<&2, WeightedJob> -> List<&2, WeightedJob> -> Plan) -> Plan:
  (left, right) = groups
  next(group_jobs(left), group_jobs(right))

def serial_cutoff() -> F32:
  4096.0

def small(count: Nat, work: F32) -> Bool:
  Bool.and(Nat.is_le(count, 4n), F32.is_le(work, serial_cutoff()))

def total_work(jobs: List<&2, WeightedJob>, acc: F32) -> F32:
  match jobs:
    case Nil{}:
      acc
    case WeightedJob{_, work, _, _, _} <> tail:
      total_work(tail, F32.add(acc, work))

def homogeneous(jobs: List<&2, WeightedJob>, +work: F32) -> Bool:
  match jobs:
    case Nil{}:
      True{}
    case WeightedJob{_, cost, _, _, _} <> tail:
      Bool.and(F32.is_eq(work, cost), homogeneous(tail, work))

def balanced(fuel: Nat, +count: Nat, +work: F32, jobs: List<&2, WeightedJob>, serial: Bool) -> Plan:
  match fuel jobs serial:
    case _ Nil{} _:
      Empty{}
    case _ WeightedJob{index, _, qn, tn, job} <> Nil{} _:
      SizedLeaf{index, qn, tn, job}
    case 0n _ _:
      Serial{jobs}
    case _ _ True{}:
      Serial{jobs}
    case Succ{+p} +values False{}:
      +half = Nat.div(count, 2n)
      +rest = Nat.sub(count, half)
      Fork{balanced(p, half, work, List.take(&2, WeightedJob, values, half),
             small(half, F32.mul(work, F32.from_nat(half)))),
           balanced(p, rest, work, List.drop(&2, WeightedJob, values, half),
             small(rest, F32.mul(work, F32.from_nat(rest))))}

def plan(fuel: Nat, jobs: List<&2, WeightedJob>, serial: Bool) -> Plan:
  match fuel jobs serial:
    case _ Nil{} _:
      Empty{}
    case _ WeightedJob{index, _, qn, tn, job} <> Nil{} _:
      SizedLeaf{index, qn, tn, job}
    case 0n _ _:
      Serial{jobs}
    case _ _ True{}:
      Serial{jobs}
    case Succ{+p} +values False{}:
      +count = List.length(&2, WeightedJob, values)
      +half = Nat.div(count, 2n)
      plan_step(partition(values,
        (Group{half, 0.0, Nil{}}, Group{Nat.sub(count, half), 0.0, Nil{}})),
        +left => +right => Fork{
          plan(p, left, small(half, total_work(left, 0.0))),
          plan(p, right, small(Nat.sub(count, half), total_work(right, 0.0)))})

def prepare.choose(+jobs: List<&2, WeightedJob>, +count: Nat, +work: F32, same: Bool) -> Plan:
  match same:
    case True{}:
      Ordered{balanced(count, count, work, jobs, small(count, F32.mul(work, F32.from_nat(count))))}
    case False{}:
      plan(count, List.sort(~WeightedJob, ~heavier, jobs), small(count, total_work(jobs, 0.0)))

def prepare.indexed(+jobs: List<&2, WeightedJob>) -> Plan:
  match jobs:
    case Nil{}:
      Empty{}
    case WeightedJob{_, +work, _, _, _} <> tail:
      prepare.choose(jobs, List.length(&2, WeightedJob, jobs), work, homogeneous(tail, work))

def prepare(jobs: List<&2, E.AlignJob>) -> Plan:
  match jobs:
    case Nil{}:
      Empty{}
    case job <> Nil{}:
      Leaf{0n, job}
    case _:
      prepare.indexed(indexed(jobs, 0n))

def single(index: Nat, job: E.AlignJob) -> IndexedResult:
  E.AlignJob{query, target, config} = job
  IndexedResult{index, M.edlib_align(query, target, config)}

def single_sized(index: Nat, query_length: Nat, target_length: Nat, job: E.AlignJob) -> IndexedResult:
  E.AlignJob{query, target, config} = job
  IndexedResult{index, M.edlib_align_sized(query, target, config, query_length, target_length)}

def serial(jobs: List<&2, WeightedJob>) -> List<&2, IndexedResult>:
  match jobs:
    case Nil{}:
      Nil{}
    case WeightedJob{index, _, qn, tn, job} <> tail:
      single_sized(index, qn, tn, job) <> serial(tail)

# Only ready, independent subplans enter parallel calls. A leaf uses the same
# single-pair implementation; column carries and successive columns stay serial.
def execute(plan: Plan) -> List<&2, IndexedResult>:
  match plan:
    case Empty{}:
      Nil{}
    case Leaf{index, job}:
      [single(index, job)]
    case SizedLeaf{index, qn, tn, job}:
      [single_sized(index, qn, tn, job)]
    case Ordered{plan}:
      execute(plan)
    case Serial{jobs}:
      serial(jobs)
    case Fork{left, right}:
      a b = execute(left) execute(right)
      List.append(&2, IndexedResult, a, b)

def earlier(first: IndexedResult, second: IndexedResult) -> Bool:
  IndexedResult{a, _} = first
  IndexedResult{b, _} = second
  Nat.is_le(a, b)

def results(values: List<&2, IndexedResult>) -> List<&2, E.AlignResult>:
  match values:
    case Nil{}:
      Nil{}
    case IndexedResult{_, result} <> tail:
      result <> results(tail)

type Gathered is Type:
  Gathered{array: Array<Maybe<&2, E.AlignResult>>, valid: Bool}

def gather.occupied(result: Array<Maybe<&2, E.AlignResult>> & Maybe<&2, E.AlignResult>) -> Gathered:
  match result:
    case (array, None{}):
      Gathered{array, True{}}
    case (array, Some{_}):
      Gathered{array, False{}}

def gather.one(array: Array<Maybe<&2, E.AlignResult>>, index: Nat, value: E.AlignResult,
                  in_bounds: Bool) -> Gathered:
  match in_bounds:
    case True{}:
      gather.occupied(Array.swap(Maybe<&2, E.AlignResult>, array, U32.from_nat(index), Some{value}))
    case False{}:
      Gathered{array, False{}}

def gather.store(values: List<&2, IndexedResult>, +count: Nat, state: Gathered) -> Gathered:
  match values state:
    case Nil{} _:
      state
    case _ Gathered{array, False{}}:
      Gathered{array, False{}}
    case IndexedResult{+index, value} <> tail Gathered{array, True{}}:
      gather.store(tail, count, gather.one(array, index, value, Nat.is_lt(index, count)))

type GatherOutput is Type:
  GatherOutput{array: Array<Maybe<&2, E.AlignResult>>, values: List<&2, E.AlignResult>, valid: Bool}

def gather.consumed(values: List<&2, E.AlignResult>,
                       result: Array<Maybe<&2, E.AlignResult>> & Maybe<&2, E.AlignResult>) -> GatherOutput:
  match result:
    case (array, Some{value}):
      GatherOutput{array, value <> values, True{}}
    case (array, None{}):
      GatherOutput{array, values, False{}}

def gather.consume(fuel: Nat, +index: U32, state: GatherOutput) -> Maybe<&2, List<&2, E.AlignResult>>:
  match fuel state:
    case _ GatherOutput{_, _, False{}}:
      None{}
    case 0n GatherOutput{_, values, True{}}:
      Some{List.reverse(&2, E.AlignResult, values)}
    case 1n+p GatherOutput{array, values, True{}}:
      gather.consume(p, U32.inc(index), gather.consumed(values,
        Array.swap(Maybe<&2, E.AlignResult>, array, index, None{})))

def gather.finish(count: Nat, state: Gathered) -> Maybe<&2, List<&2, E.AlignResult>>:
  match state:
    case Gathered{array, True{}}:
      gather.consume(count, 0, GatherOutput{array, Nil{}, True{}})
    case Gathered{_, False{}}:
      None{}

def gather(values: List<&2, IndexedResult>, +count: Nat) -> Maybe<&2, List<&2, E.AlignResult>>:
  gather.finish(count, gather.store(values, count, Gathered{
    Array.new(Maybe<&2, E.AlignResult>, P.depth(count), None{}), True{}}))

def ordered.gathered(original: List<&2, IndexedResult>, maybe: Maybe<&2, List<&2, E.AlignResult>>) ->
                     List<&2, E.AlignResult>:
  match maybe:
    case Some{values}:
      values
    case None{}:
      results(List.sort(~IndexedResult, ~earlier, original))

# Indexed gathering wins for larger permutations; validate indexes and occupied
# slots before accessing wrapping arrays. Preserve sorting for arbitrary indexes.
def ordered.choose(+values: List<&2, IndexedResult>, count: Nat, use_array: Bool) -> List<&2, E.AlignResult>:
  match use_array:
    case True{}:
      ordered.gathered(values, gather(values, count))
    case False{}:
      results(List.sort(~IndexedResult, ~earlier, values))

def ordered(+values: List<&2, IndexedResult>) -> List<&2, E.AlignResult>:
  +count = List.length(&2, IndexedResult, values)
  ordered.choose(values, count, Bool.and(Nat.is_ge(count, 256n), Nat.is_le(count, 65536n)))

def align_plan(plan: Plan) -> List<&2, E.AlignResult>:
  match plan:
    case Ordered{inner}:
      results(execute(inner))
    case _:
      ordered(execute(plan))

def align_batch(jobs: List<&2, E.AlignJob>) -> List<&2, E.AlignResult>:
  match jobs:
    case Nil{}:
      Nil{}
    case E.AlignJob{query, target, config} <> Nil{}:
      [M.edlib_align(query, target, config)]
    case values:
      align_plan(prepare(values))
