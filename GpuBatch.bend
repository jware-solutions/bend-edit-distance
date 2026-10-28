import ./src/PreparedPool.bend as P
import ./Prepared.bend as Q
import ./src/Myers.bend as M
import Base
import ./src/Batch.bend as B
import ./EdlibTypes.bend as E

# Keep host planning and ordered-result restoration outside the single bang.
# The same independent alignment leaves and carry dependencies serve both chips.
def execute(plan: B.Plan) -> List<&2, B.IndexedResult>:
  B.execute!(plan)

def ordered(values: List<&2, B.IndexedResult>) -> List<&2, E.AlignResult>:
  B.ordered(values)

def align_plan(plan: B.Plan) -> List<&2, E.AlignResult>:
  match plan:
    case B.Ordered{inner}:
      B.results(execute(inner))
    case _:
      ordered(execute(plan))

# Explicit opt-in module: CPU consumers of lib.bend need no GPU toolchain.
def align_batch(jobs: List<&2, E.AlignJob>) -> List<&2, E.AlignResult>:
  align_plan(B.prepare(jobs))

# Persistent prepared sessions keep independently owned profiles/workspaces.
# Only the ready plan enters the bang; buffers are cloned during preparation.
def prepare_query(query: String, pairs: List<&2, E.EqualityPair>) -> P.Pool:
  P.prepare(query, pairs)

def execute_prepared(plan: P.Plan, options: Q.Options, known_bytes: Bool) -> P.PoolDone:
  P.execute!(plan, options, known_bytes)

def align_prepared_ready(ready: P.PoolReady, options: Q.Options, known_bytes: Bool) -> P.Pool & List<&2, E.AlignResult>:
  P.PoolReady{plan, idle, shards, length, budget, ordered} = ready
  P.finish(idle, shards, length, budget, ordered, execute_prepared(plan, options, known_bytes))

def wave_join(before: List<&2, E.AlignResult>, result: P.Pool & List<&2, E.AlignResult>) ->
               P.Pool & List<&2, E.AlignResult>:
  (pool, after) = result
  (pool, List.append(&2, E.AlignResult, before, after))

def wave_next(next: P.Pool -> (P.Pool & List<&2, E.AlignResult>),
                result: P.Pool & List<&2, E.AlignResult>) -> P.Pool & List<&2, E.AlignResult>:
  (pool, before) = result
  wave_join(before, next(pool))

# One target per owner per bang avoids a pinned-runtime completion failure
# observed when every CUDA leaf reuses its owner for a second target. Planning
# each bounded wave on the host also caps the live device execution tree.
def waves(fuel: Nat, pool: P.Pool, +targets: List<&2, String>, options: Q.Options,
            known_bytes: Bool) -> P.Pool & List<&2, E.AlignResult>:
  match fuel pool targets:
    case _ _ Nil{}:
      (pool, Nil{})
    case 0n _ _:
      P.align_batch(pool, targets, options)
    case 1n+p P.Pool{owners, +shards, length, budget} _:
      +count = Nat.max(1n, Nat.min(1024n, shards))
      +shared = {options : Q.Options}
      +known = {known_bytes : Bool}
      head = List.take(&2, String, targets, count)
      tail = List.drop(&2, String, targets, count)
      ready = P.ready(P.Pool{owners, shards, length, budget}, head, shared)
      wave_next(owner => waves(p, owner, tail, shared, known), align_prepared_ready(ready, shared, known))

def align_prepared_batch(pool: P.Pool, targets: List<&2, String>, options: Q.Options) ->
                         P.Pool & List<&2, E.AlignResult>:
  waves(65536n, pool, targets, options, False{})

def single_result(value: P.Pool & List<&2, E.AlignResult>) -> P.Pool & E.AlignResult:
  match value:
    case (pool, result <> _):
      (pool, result)
    case (pool, Nil{}):
      (pool, E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}})

def align_prepared(pool: P.Pool, target: String, options: Q.Options) -> P.Pool & E.AlignResult:
  single_result(align_prepared_batch(pool, [target], options))

def align_single(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  M.edlib_align!(query, target, config)


# The binary codec constructs exactly one Char per byte. These transport-only
# entry points can skip the generic String byte-domain scan.
def align_prepared_batch_bytes(pool: P.Pool, targets: List<&2, String>, options: Q.Options) ->
                               P.Pool & List<&2, E.AlignResult>:
  waves(65536n, pool, targets, options, True{})

def align_prepared_bytes(pool: P.Pool, target: String, options: Q.Options) -> P.Pool & E.AlignResult:
  single_result(align_prepared_batch_bytes(pool, [target], options))
