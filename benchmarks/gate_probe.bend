import ../src/BitVector.bend as V
import Base
import ../EdlibTypes.bend as E
import ../src/Batch.bend as B
import ../src/Myers.bend as M
import ../src/Alignment.bend as A
import ../src/Reconstruction.bend as R
import ../src/Transport.bend as BT
import ./gate_metrics.bend as T

# The harness substitutes only this body in its temporary GPU source copy.
def execute(plan: B.Plan) -> List<&2, B.IndexedResult>:
  B.execute(plan)

type Axes is Data:
  Axes{query: String, target: String, length: Nat, columns: Nat}

type Scanned is Data:
  Nw{distance: E.EditDistance}
  Semi{best: A.Best}

type Resolved is Data:
  Resolved{best: A.Best, accepted: Bool}

def orient(q: String, t: String, qn: Nat, tn: Nat, swap: Bool) -> Axes:
  match swap:
    case True{}:
      Axes{t, q, tn, qn}
    case False{}:
      Axes{q, t, qn, tn}

def axes(+q: String, +t: String, mode: E.Mode) -> Axes:
  match mode:
    case E.NW{}:
      +qn +tn = String.length(q) String.length(t)
      orient(q, t, qn, tn, Nat.is_gt(qn, tn))
    case _:
      Axes{q, t, String.length(q), String.length(t)}

def profile(input: Axes, pairs: List<&2, E.EqualityPair>) -> List<&2, V.Peq>:
  Axes{q, _, n, _} = input
  V.build_peq(V.ceil_div(n, 32n), q, pairs)

def scan(input: Axes, profiles: List<&2, V.Peq>, mode: E.Mode,
         threshold: E.Threshold) -> Scanned:
  match input mode:
    case Axes{_, t, qn, tn} E.NW{}:
      Nw{M.search_distance(M.search_profiles(t, profiles, qn, tn, threshold))}
    case Axes{_, t, +qn, _} +m:
      Semi{M.semiglobal_best(t, profiles, qn, M.semiglobal_maximum(threshold, qn), m)}

def resolve_hw(job: E.AlignJob, best: A.Best) -> A.Best:
  match job best:
    case E.AlignJob{_, _, E.AlignConfig{_, E.Distance{}, _, _, _}} _:
      best
    case E.AlignJob{+q, +t, E.AlignConfig{E.HW{}, _, _, +pairs, _}} A.Best{+score, +locations}:
      +qn +tn = String.length(q) String.length(t)
      rq rt = String.reverse(q) String.reverse(t)
      A.Best{score, M.hw_locations(List.length(&2, A.Location, locations), locations,
        rt, tn, V.build_peq(V.ceil_div(qn, 32n), rq, pairs), qn, U32.to_nat(score))}
    case _ _:
      best

def accepted(job: E.AlignJob, best: A.Best, within: Bool) -> Resolved:
  match within:
    case True{}:
      Resolved{resolve_hw(job, best), True{}}
    case False{}:
      Resolved{best, False{}}

def resolve_semi(+job: E.AlignJob, +best: A.Best) -> Resolved:
  E.AlignJob{_, _, E.AlignConfig{_, _, threshold, _, _}} = job
  A.Best{score, _} = best
  accepted(job, best, E.within_threshold(threshold, U32.to_nat(score)))

def resolve(job: E.AlignJob, scanned: Scanned) -> Resolved:
  match job scanned:
    case E.AlignJob{_, t, _} Nw{E.Found{score}}:
      Resolved{A.Best{U32.from_nat(score), [A.Location{E.end_coordinate(String.length(t)), 0n}]}, True{}}
    case _ Nw{E.NotFound{}}:
      Resolved{A.Best{0, Nil{}}, False{}}
    case +value Semi{+best}:
      resolve_semi(value, best)

def restore(job: E.AlignJob, resolved: Resolved) -> IO(E.AlignResult):
  match job resolved:
    case E.AlignJob{+q, +t, E.AlignConfig{_, E.Path{}, _, +pairs, format}}
         Resolved{A.Best{score, +location <> tail}, True{}}:
      +segment = A.span(t, location)
      do IO<E.AlignResult>:
        operations : List<&2, E.Operation> <- T.mark(List<&2, E.Operation>, 5, R.reconstruct(q, segment, pairs))
        T.mark(E.AlignResult, 9, A.path_validate(q, segment, pairs, score, location <> tail,
          format, operations, A.location_valid(t, location)))
    case E.AlignJob{q, t, E.AlignConfig{_, task, _, pairs, format}} Resolved{best, within}:
      T.mark(E.AlignResult, 9, A.result(q, t, task, pairs, format, best, within))

def nonempty(+job: E.AlignJob) -> IO(E.AlignResult):
  E.AlignJob{q, t, E.AlignConfig{+mode, _, +threshold, pairs, _}} = job
  do IO<E.AlignResult>:
    input : Axes <- T.mark(Axes, 7, axes(q, t, mode))
    +shared : Axes = input
    profiles : List<&2, V.Peq> <- T.mark(List<&2, V.Peq>, 3, profile(shared, pairs))
    found : Scanned <- T.mark(Scanned, 4, scan(shared, profiles, mode, threshold))
    resolved : Resolved <- T.mark(Resolved, 8, resolve(job, found))
    restore(job, resolved)

def phased_job(+job: E.AlignJob) -> IO(E.AlignResult):
  match job:
    case E.AlignJob{SNil{}, t, config}:
      T.mark(E.AlignResult, 9, M.edlib_align("", t, config))
    case E.AlignJob{q, SNil{}, config}:
      T.mark(E.AlignResult, 9, M.edlib_align(q, "", config))
    case _:
      nonempty(job)

# These serial diagnostics isolate stage costs; public batch throughput is
# measured independently by the unchanged parallel Batch execution tree.
def phased(jobs: List<&2, E.AlignJob>) -> IO(List<&2, E.AlignResult>):
  match jobs:
    case Nil{}:
      IO.pure(List<&2, E.AlignResult>, Nil{})
    case job <> tail:
      do IO<List<&2, E.AlignResult>>:
        head : E.AlignResult <- phased_job(job)
        rest : List<&2, E.AlignResult> <- phased(tail)
        return head <> rest

def reused(jobs: List<&2, E.AlignJob>, +profiles: List<&2, V.Peq>) -> IO(List<&2, E.AlignResult>):
  match jobs:
    case Nil{}:
      IO.pure(List<&2, E.AlignResult>, Nil{})
    case +job <> tail:
      E.AlignJob{q, t, E.AlignConfig{+mode, _, threshold, _, _}} = job
      do IO<List<&2, E.AlignResult>>:
        input : Axes <- T.mark(Axes, 7, axes(q, t, mode))
        found : Scanned <- T.mark(Scanned, 4, scan(input, profiles, mode, threshold))
        resolved : Resolved <- T.mark(Resolved, 8, resolve(job, found))
        head : E.AlignResult <- restore(job, resolved)
        rest : List<&2, E.AlignResult> <- reused(tail, profiles)
        return head <> rest

def prepared(jobs: List<&2, E.AlignJob>) -> IO(List<&2, E.AlignResult>):
  match jobs:
    case Nil{}:
      IO.pure(List<&2, E.AlignResult>, Nil{})
    case +job <> tail:
      E.AlignJob{q, t, E.AlignConfig{mode, _, _, pairs, _}} = job
      do IO<List<&2, E.AlignResult>>:
        input : Axes <- T.mark(Axes, 7, axes(q, t, mode))
        profiles : List<&2, V.Peq> <- T.mark(List<&2, V.Peq>, 3, profile(input, pairs))
        reused(job <> tail, profiles)

def compute(mode: String, jobs: List<&2, E.AlignJob>) -> IO(List<&2, E.AlignResult>):
  match mode:
    case "phases":
      phased(jobs)
    case "prepared":
      prepared(jobs)
    case "batch":
      do IO<List<&2, E.AlignResult>>:
        plan : B.Plan <- T.mark(B.Plan, 0, B.prepare(jobs))
        values : List<&2, B.IndexedResult> <- T.mark(List<&2, B.IndexedResult>, 1, execute(plan))
        T.mark(List<&2, E.AlignResult>, 2, B.ordered(values))
    case _:
      IO.die(List<&2, E.AlignResult>, 2, "Expected batch, phases or prepared")

def rounds(fuel: Nat, +count: Nat, +mode: String) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(count)
        T.reset()
        values : List<&2, E.AlignResult> <- compute(mode, jobs)
        BT.write_batch(values)
        done : Unit <- T.mark(Unit, 6, Unit{})
        T.finish()
        rounds(p, count, mode)

def parsed(mode: String, count: Maybe<&2, Nat>, repeat: Maybe<&2, Nat>) -> IO(Unit):
  match count repeat:
    case Some{n} Some{r}:
      rounds(r, n, mode)
    case _ _:
      IO.die(Unit, 2, "Expected natural COUNT ROUNDS")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> mode <> count <> repeat <> Nil{}:
      parsed(mode, Nat.read(count), Nat.read(repeat))
    case _:
      IO.die(Unit, 2, "Expected MODE COUNT ROUNDS")

def main() -> IO(Unit):
  do IO<Unit>:
    T.ready()
    args : List<String> <- IO.args()
    run(args)
