import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../lib.bend as L
import ../src/PreparedPool.bend as P
import ../src/Transport.bend as T

def combined(before: List<&2, E.AlignResult>, value: P.Pool & E.AlignResult) -> List<&2, E.AlignResult>:
  (_, last) = value
  List.append(&2, E.AlignResult, before, [last])

def reused(target: String, options: Q.Options, value: P.Pool & List<&2, E.AlignResult>) -> List<&2, E.AlignResult>:
  (pool, before) = value
  combined(before, L.align_prepared_pool(pool, target, options))

def pooled(query: String, +target: String, pairs: List<&2, E.EqualityPair>, +options: Q.Options) -> List<&2, E.AlignResult>:
  reverse_target = String.reverse(target)
  reused(target, options, L.align_prepared_pool_batch(L.prepare_pool(query, pairs, 4n),
    [target, reverse_target, "", target], options))

def run(+query: String, +target: String, +config: E.AlignConfig) -> IO(Unit):
  E.AlignConfig{mode, task, threshold, pairs, format} = config
  do IO<Unit>:
    T.write_batch(pooled(query, target, pairs, Q.Options{mode, task, threshold, format}))
    T.write_batch([L.align(query, target, config), L.align(query, String.reverse(target), config),
      L.align(query, "", config), L.align(query, target, config), L.align(query, target, config)])

def variant(kind: String, query: String, target: String, config: E.AlignConfig) -> IO(Unit):
  match kind:
    case "both":
      run(SCon{Chr{256}, query}, SCon{Chr{256}, target}, config)
    case "target":
      run(query, SCon{Chr{256}, target}, config)
    case _:
      run(query, target, config)

def job(args: List<String>, value: E.AlignJob) -> IO(Unit):
  match args value:
    case _ <> kind <> Nil{} E.AlignJob{query, target, config}:
      variant(kind, query, target, config)
    case _ E.AlignJob{query, target, config}:
      run(query, target, config)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    value : E.AlignJob <- T.job(request)
    job(args, value)
