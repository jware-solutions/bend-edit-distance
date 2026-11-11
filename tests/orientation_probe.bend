import Base
import ../EdlibTypes.bend as E
import ../src/Myers.bend as M
import ../src/Transport.bend as T

# Force orientation only in the test executable. Restoration always receives
# the original inputs, including insert/delete directions and target endpoints.
def oriented(+q: String, +t: String, +config: E.AlignConfig, forward: Bool) -> E.AlignResult:
  match q t config:
    case SNil{} _ _:
      M.edlib_align(q, t, config)
    case _ SNil{} _:
      M.edlib_align(q, t, config)
    case _ _ E.AlignConfig{E.NW{}, task, threshold, +pairs, format}:
      +qn +tn = String.length(q) String.length(t)
      M.nw_result(q, t, task, pairs, format, E.end_coordinate(tn),
        M.search_distance(M.search_shorter(q, t, qn, tn, threshold, forward, pairs)))
    case _ _ _:
      M.edlib_align(q, t, config)

def run(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+q, +t, +config} = job
  [M.edlib_align(q, t, config), oriented(q, t, config, True{}), oriented(q, t, config, False{})]

def rounds(fuel: Nat, request: T.Request) -> IO(Unit):
  match fuel request:
    case _ T.End{}:
      IO.pure(Unit, Unit{})
    case 0n _:
      IO.pure(Unit, Unit{})
    case 1n+p _:
      do IO<Unit>:
        job : E.AlignJob <- T.job(request)
        T.write_batch(run(job))
        next : T.Request <- T.read_request()
        rounds(p, next)

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    rounds(4294967295n, request)
