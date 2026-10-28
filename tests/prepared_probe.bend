import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../lib.bend as L
import ../src/Transport.bend as T

def apply(prepared: Q.Prepared, target: String, options: Q.Options) -> E.AlignResult:
  Q.result(L.align_prepared(prepared, target, options))

def cloned(+target: String, +options: Q.Options, owners: Q.Prepared & Q.Prepared) -> List<&2, E.AlignResult>:
  (first, second) = owners
  reverse_target = String.reverse(target)
  a b = apply(first, target, options) apply(second, reverse_target, options)
  [a, b]

def reused(target: String, options: Q.Options, value: Q.Prepared & E.AlignResult) -> List<&2, E.AlignResult>:
  (prepared, _) = value
  cloned(target, options, L.clone_prepared(prepared))

def run(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{query, +target, E.AlignConfig{mode, task, threshold, pairs, format}} = job
  +options = {Q.Options{mode, task, threshold, format} : Q.Options}
  reused(target, options, L.align_prepared(L.prepare(query, pairs), target, options))

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(run(job))
