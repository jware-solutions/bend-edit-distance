import Base
import ./EdlibTypes.bend as E
import ./main.bend as M

type WeightedJob is Data:
  WeightedJob{index: Nat, work: F32, job: E.AlignJob}

type Group is Data:
  Group{room: Nat, work: F32, jobs: List<&2, WeightedJob>}

# Build the entire plan before entering the alignment fork tree. Recursive
# argument preparation in a parallel call can drain the native frontier.
type Plan is Type:
  Empty{}
  Leaf{index: Nat, job: E.AlignJob}
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
  +blocks = F32.from_nat(M.ceil_div(length, 32n))
  +p = (1.0 + F32.from_nat(List.length(&2, E.EqualityPair, pairs)) : F32)
  (1.0 + l + c + 256.0 * l * p + blocks * c +
    extra_work(mode, task, l, c, blocks, p) : F32)

# A scheduling heuristic, not a timing prediction: input scans, 256-symbol
# profiles, full Myers columns, worst-case HW start searches and PATH DP.
# F32 avoids wrapping a U32 product or allocating a quadratic unary Nat.
# Bands, retries, similarity and the selected interval can change actual work.
def estimate_sizes(qn: Nat, tn: Nat, config: E.AlignConfig) -> F32:
  match qn tn config:
    case 0n +t _:
      (1.0 + F32.from_nat(t) : F32)
    case +q 0n _:
      (1.0 + F32.from_nat(q) : F32)
    case +q +t E.AlignConfig{+mode, task, _, pairs, _}:
      estimate_axes(mode, task, pairs, axes(mode, q, t))

def estimate(+job: E.AlignJob) -> F32:
  E.AlignJob{query, target, config} = job
  # Scans are sequential here; pairs of arbitrary lengths need not balance.
  estimate_sizes(String.length(query), String.length(target), config)

def indexed(jobs: List<&2, E.AlignJob>, +index: Nat) -> List<&2, WeightedJob>:
  match jobs:
    case Nil{}:
      Nil{}
    case +job <> tail:
      WeightedJob{index, estimate(job), job} <> indexed(tail, 1n+index)

def heavier(first: WeightedJob, second: WeightedJob) -> Bool:
  WeightedJob{_, a, _} = first
  WeightedJob{_, b, _} = second
  F32.is_ge(a, b)

def add(group: Group, job: WeightedJob) -> Group:
  Group{room, work, jobs} = group
  WeightedJob{index, +cost, value} = job
  Group{Nat.sub(room, 1n), F32.add(work, cost), WeightedJob{index, cost, value} <> jobs}

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

def plan(fuel: Nat, jobs: List<&2, WeightedJob>) -> Plan:
  match fuel jobs:
    case _ Nil{}:
      Empty{}
    case _ WeightedJob{index, _, job} <> Nil{}:
      Leaf{index, job}
    case 0n values:
      Serial{values}
    case Succ{+p} +values:
      +count = List.length(&2, WeightedJob, values)
      +half = Nat.div(count, 2n)
      plan_step(partition(values,
        (Group{half, 0.0, Nil{}}, Group{Nat.sub(count, half), 0.0, Nil{}})),
        left => right => Fork{plan(p, left), plan(p, right)})

def prepare(+jobs: List<&2, E.AlignJob>) -> Plan:
  plan(List.length(&2, E.AlignJob, jobs),
    List.sort(~WeightedJob, ~heavier, indexed(jobs, 0n)))

def single(index: Nat, job: E.AlignJob) -> IndexedResult:
  E.AlignJob{query, target, config} = job
  IndexedResult{index, M.edlib_align(query, target, config)}

def serial(jobs: List<&2, WeightedJob>) -> List<&2, IndexedResult>:
  match jobs:
    case Nil{}:
      Nil{}
    case WeightedJob{index, _, job} <> tail:
      single(index, job) <> serial(tail)

# Only ready, independent subplans enter parallel calls. A leaf uses the same
# single-pair implementation; column carries and successive columns stay serial.
def execute(plan: Plan) -> List<&2, IndexedResult>:
  match plan:
    case Empty{}:
      Nil{}
    case Leaf{index, job}:
      [single(index, job)]
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

def align_batch(jobs: List<&2, E.AlignJob>) -> List<&2, E.AlignResult>:
  match jobs:
    case Nil{}:
      Nil{}
    case E.AlignJob{query, target, config} <> Nil{}:
      [M.edlib_align(query, target, config)]
    case values:
      results(List.sort(~IndexedResult, ~earlier, execute(prepare(values))))
