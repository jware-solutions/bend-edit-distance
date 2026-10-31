import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../src/RetryHint.bend as H
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/Word.bend as Word
import ../src/SearchKernel.bend as K
import ../src/Transport.bend as T

def hint_result(hint: H.Hint) -> E.AlignResult:
  match hint:
    case H.Unavailable{}:
      E.not_found()
    case H.Bounded{d}:
      E.distance_result(d, E.BeforeStart{}, True{})

def reused(query: String, target: String, +length: Nat, pairs: List<&2, E.EqualityPair>, value: H.Hinted) -> List<&2, E.AlignResult>:
  H.Hinted{profile, hint} = value
  [hint_result(hint), Q.result(Q.align(Q.Prepared{query, pairs, length, Some{profile}, W.new(Word.blocks(length))},
    target, Q.default_options()))]

def run(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = job
  +length = String.length(query)
  reused(query, target, length, pairs,
    H.scan(length, target, 0, Nat.div(length, 8n), H.Scanning{P.build(query, length, pairs), 0n, False{}}))

def distance_result(distance: E.EditDistance) -> E.AlignResult:
  match distance:
    case E.Found{d}:
      E.distance_result(d, E.BeforeStart{}, True{})
    case E.NotFound{}:
      E.not_found()

def metric(value: Nat) -> E.AlignResult:
  E.distance_result(value, E.BeforeStart{}, True{})

def metrics(value: K.Run) -> List<&2, E.AlignResult>:
  K.Run{_, _, K.Stats{distance, blocks, columns, attempts}} = value
  [distance_result(distance), metric(blocks), metric(columns), metric(attempts)]

def kernel(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  List.append(&2, E.AlignResult,
    metrics(H.search(target, P.build(query, length, pairs), W.new(Word.blocks(length)), length, columns)),
    List.append(&2, E.AlignResult,
      metrics(K.search(target, P.build(query, length, pairs), W.new(Word.blocks(length)), length, columns, E.Unlimited{})),
      metrics(K.attempt(target, P.build(query, length, pairs), W.new(Word.blocks(length)), length, columns, Word.width(), Word.padding(length)))))

def args(values: List<String>, job: E.AlignJob) -> List<&2, E.AlignResult>:
  match values:
    case _ <> "stats" <> Nil{}:
      kernel(job)
    case _:
      run(job)

def main() -> IO(Unit):
  do IO<Unit>:
    values : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(args(values, job))
