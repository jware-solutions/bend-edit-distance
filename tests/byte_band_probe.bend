import ../src/BitVector.bend as V
import ../src/ByteTarget.bend as BT
import Base
import ../EdlibTypes.bend as E
import ../src/ByteKernel.bend as Bytes
import ../src/RetryHint.bend as Hint
import ../src/SearchKernel.bend as K
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/Word.bend as Word
import ../src/Transport.bend as T
import ../src/Myers.bend as M
import ./prepared_bytes_probe.bend as Packed
import ./dense_kernel.bend as Dense

def distance(value: E.EditDistance) -> E.AlignResult:
  match value:
    case E.Found{d}:
      E.distance_result(d, E.BeforeStart{}, True{})
    case E.NotFound{}:
      E.not_found()

def metric(value: Nat) -> E.AlignResult:
  E.distance_result(value, E.BeforeStart{}, True{})

def metrics(value: K.Stats) -> List<&2, E.AlignResult>:
  K.Stats{d, blocks, columns, attempts} = value
  [distance(d), metric(blocks), metric(columns), metric(attempts)]

def compare(+count: Nat, a: K.Run, b: K.Run) -> List<&2, E.AlignResult>:
  K.Run{_, W.Workspace{ad, +ac, +af, +al}, astats} = a
  K.Run{_, W.Workspace{bd, +bc, +bf, +bl}, bstats} = b
  same = Bool.and(Bool.and(U32.is_eq(ac, bc), Bool.and(U32.is_eq(af, bf), U32.is_eq(al, bl))),
    Packed.same_blocks(Packed.blocks(count, 0, W.Workspace{ad, ac, af, al}),
      Packed.blocks(count, 0, W.Workspace{bd, bc, bf, bl})))
  List.append(&2, E.AlignResult, metrics(astats),
    List.append(&2, E.AlignResult, metrics(bstats), [metric(Bool.pick(Nat, same, 1n, 0n))]))

# Independent Nat control: every attempt uses the guarded column oracle.
# In particular, the packed and String production routes are not each other's
# reference for shared SearchKernel control changes.
def nw_reference(target: String, +length: Nat, +target_length: Nat, +padding: Nat,
                     +column: Nat, blocks: Nat, state: K.ColumnReady) -> K.Run:
  match target state:
    case _ K.ColumnReady{profile, workspace, _, work, True{}}:
      K.Run{profile, workspace, K.Stats{E.NotFound{}, Nat.add(blocks, work), column, 1n}}
    case SNil{} K.ColumnReady{profile, W.Workspace{data, +capacity, first, +last}, maximum, work, False{}}:
      K.finish(profile, W.Workspace{data, capacity, first, last}, maximum, padding,
        Nat.add(blocks, work), column, U32.is_eq(last, capacity))
    case SCon{h, t} K.ColumnReady{profile, workspace, maximum, work, False{}}:
      +symbol = Char.to_u32(h)
      nw_reference(t, length, target_length, padding, 1n+column, Nat.add(blocks, work),
        K.ready(K.step.updated(symbol, length, target_length, 1n+column, maximum, padding,
          W.column_reference(profile, workspace, symbol, V.Carry{1, 0}))))

def attempt_reference(target: String, profile: P.Profile, workspace: W.Workspace,
                          +length: Nat, +columns: Nat, +maximum: Nat, padding: Nat) -> K.Run:
  nw_reference(target, length, columns, padding, 0n, 0n,
    K.ready(K.Step{profile, W.initialize(workspace, K.initial_count(length, columns, maximum)), maximum, 0n}))

def adaptive_reference(fuel: Nat, +target: String, +length: Nat, +columns: Nat,
                           +maximum: Nat, +padding: Nat, result: K.Run) -> K.Run:
  match fuel result:
    case _ K.Run{profile, workspace, K.Stats{E.Found{value}, blocks, consumed, attempts}}:
      K.Run{profile, workspace, K.Stats{E.Found{value}, blocks, consumed, attempts}}
    case 0n _:
      result
    case 1n+p K.Run{profile, workspace, stats}:
      adaptive_reference(p, target, length, columns, Nat.min(Nat.max(length, columns), Nat.mul(maximum, 2n)), padding,
        K.accumulated(stats, attempt_reference(target, profile, workspace, length, columns, maximum, padding)))

def retry_reference(+target: String, +length: Nat, workspace: W.Workspace, stats: K.Stats, value: Hint.Hinted) -> K.Run:
  match value:
    case Hint.Hinted{profile, Hint.Unavailable{}}:
      adaptive_reference(1n+length, target, length, length, Nat.mul(Word.width(), 2n), Word.padding(length),
        K.Run{profile, workspace, stats})
    case Hint.Hinted{profile, Hint.Bounded{upper}}:
      adaptive_reference(1n+length, target, length, length, Nat.max(1n+Word.width(), upper), Word.padding(length),
        K.Run{profile, workspace, stats})

def failed_reference(+target: String, +length: Nat, profile: P.Profile, workspace: W.Workspace,
                         stats: K.Stats, useful: Bool) -> K.Run:
  match useful:
    case False{}:
      retry_reference(target, length, workspace, stats, Hint.Hinted{profile, Hint.Unavailable{}})
    case True{}:
      retry_reference(target, length, workspace, stats,
        Hint.scan(length, target, 0, Hint.hint_limit(length), Hint.Scanning{profile, 0n, False{}}))

def first_reference(+target: String, +length: Nat, result: K.Run) -> K.Run:
  match result:
    case K.Run{profile, workspace, K.Stats{E.Found{value}, blocks, columns, attempts}}:
      K.Run{profile, workspace, K.Stats{E.Found{value}, blocks, columns, attempts}}
    case K.Run{profile, workspace, K.Stats{distance, blocks, +columns, attempts}}:
      failed_reference(target, length, profile, workspace, K.Stats{distance, blocks, columns, attempts}, Hint.use_hint(length, columns))

def unlimited_reference(+target: String, profile: P.Profile, workspace: W.Workspace,
                            +length: Nat, +columns: Nat, hinted: Bool) -> K.Run:
  match hinted:
    case True{}:
      first_reference(target, length, attempt_reference(target, profile, workspace, length, length, Word.width(), Word.padding(length)))
    case False{}:
      adaptive_reference(1n+Nat.max(length, columns), target, length, columns,
        Nat.min(Nat.max(length, columns), Nat.max(Word.width(), Nat.max(Nat.sub(columns, length), Nat.sub(length, columns)))),
        Word.padding(length), K.Run{profile, workspace, K.Stats{E.NotFound{}, 0n, 0n, 0n}})

def finite_reference(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat,
                         +columns: Nat, maximum: Nat, rejected: Bool) -> K.Run:
  match rejected:
    case True{}:
      K.Run{profile, workspace, K.Stats{E.NotFound{}, 0n, 0n, 0n}}
    case False{}:
      attempt_reference(target, profile, workspace, length, columns, Nat.min(maximum, Nat.max(length, columns)), Word.padding(length))

def reference(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat,
                  +columns: Nat, threshold: E.Threshold) -> K.Run:
  match threshold:
    case E.Unlimited{}:
      unlimited_reference(target, profile, workspace, length, columns,
        Bool.and(Nat.is_eq(length, columns), Bool.and(Nat.is_ge(length, Nat.mul(Word.width(), 32n)), Nat.is_le(length, 2147483647n))))
    case E.MaxDistance{+maximum}:
      finite_reference(target, profile, workspace, length, columns, maximum,
        Nat.is_lt(maximum, Nat.max(Nat.sub(length, columns), Nat.sub(columns, length))))

def run(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, +threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +blocks = Word.blocks(length)
  compare(blocks,
    Bytes.search(Packed.packed(target), P.build(query, length, pairs), W.new(blocks), length, threshold),
    reference(target, P.build(query, length, pairs), W.new(blocks), length, columns, threshold))

def packed_bytes(value: BT.Target) -> Array<U32>:
  BT.Target{bytes, _} = value
  bytes

def attempt_maximum(threshold: E.Threshold, length: Nat, columns: Nat) -> Nat:
  match threshold:
    case E.MaxDistance{k}:
      k
    case E.Unlimited{}:
      Nat.max(length, columns)

# Force both production attempts on equivalent, independently owned state.
def run_attempt(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +blocks = Word.blocks(length)
  +padding = Word.padding(length)
  +maximum = attempt_maximum(threshold, length, columns)
  List.append(&2, E.AlignResult,
    compare(blocks,
      attempt_reference(target, P.build(query, length, pairs), W.new(blocks), length, columns, maximum, padding),
      K.attempt(target, P.build(query, length, pairs), W.new(blocks), length, columns, maximum, padding)),
    compare(blocks,
      attempt_reference(target, P.build(query, length, pairs), W.new(blocks), length, columns, maximum, padding),
      Bytes.result(Bytes.attempt(packed_bytes(Packed.packed(target)), P.build(query, length, pairs), W.new(blocks), length, columns, maximum, padding))))

# Read every logical slot and return both owners for the next column.
type Checked is Type:
  Checked{left: W.Workspace, right: W.Workspace, same: Bool}

def check.right(left: W.Workspace, block: V.Block, same: Bool, value: W.Workspace & V.Block) -> Checked:
  V.Block{ap, am, a_score} = block
  (right, V.Block{bp, bm, bs}) = value
  Checked{left, right, Bool.and(same, Bool.and(U32.is_eq(ap, bp), Bool.and(U32.is_eq(am, bm), U32.is_eq(a_score, bs))))}

def check.left(+index: U32, right: W.Workspace, same: Bool, value: W.Workspace & V.Block) -> Checked:
  (left, block) = value
  check.right(left, block, same, W.get(right, index))

def check.blocks(fuel: Nat, +index: U32, value: Checked) -> Checked:
  match fuel value:
    case 0n _:
      value
    case 1n+p Checked{left, right, same}:
      check.blocks(p, U32.inc(index), check.left(index, right, same, W.get(left, index)))

type Compared is Type:
  Compared{empty: Bool, same: Bool, left: K.Step, right: K.Step}

def compare_steps.checked(ap: P.Profile, bp: P.Profile, am: Nat, bm: Nat, aw: Nat, bw: Nat,
                             empty: Bool, value: Checked) -> Compared:
  Checked{a, b, same} = value
  Compared{empty, same, K.Step{ap, a, am, aw}, K.Step{bp, b, bm, bw}}

def compare_steps(left: K.Step, right: K.Step) -> Compared:
  K.Step{ap, W.Workspace{ad, +ac, +af, +al}, +am, +aw} = left
  K.Step{bp, W.Workspace{bd, +bc, +bf, +bl}, +bm, +bw} = right
  compare_steps.checked(ap, bp, am, bm, aw, bw, U32.is_eq(af, al),
    check.blocks(U32.to_nat(ac), 0,
      Checked{W.Workspace{ad, ac, af, al}, W.Workspace{bd, bc, bf, bl},
        Bool.and(Bool.and(U32.is_eq(ac, bc), Bool.and(U32.is_eq(af, bf), U32.is_eq(al, bl))),
          Bool.and(Nat.is_eq(am, bm), Nat.is_eq(aw, bw)))}))

def transitions(target: String, +length: Nat, +columns: Nat, +padding: Nat, +column: Nat, value: Compared) -> Bool:
  match target value:
    case _ Compared{True{}, same, _, _}:
      same
    case SNil{} Compared{False{}, same, _, _}:
      same
    case SCon{h, t} Compared{False{}, same, K.Step{ap, a, am, _}, K.Step{bp, b, bm, _}}:
      +symbol = Char.to_u32(h)
      Bool.and(same, transitions(t, length, columns, padding, 1n+column,
        compare_steps(K.step.updated(symbol, length, columns, 1n+column, am, padding,
          W.column_reference(ap, a, symbol, V.Carry{1, 0})),
          K.step.updated(symbol, length, columns, 1n+column, bm, padding,
            W.column(bp, b, symbol, V.Carry{1, 0})))))

def run_transitions(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +maximum = attempt_maximum(threshold, length, columns)
  +blocks = Word.blocks(length)
  +count = K.initial_count(length, columns, maximum)
  [metric(Bool.pick(Nat, transitions(target, length, columns, Word.padding(length), 0n,
    compare_steps(K.Step{P.build(query, length, pairs), W.initialize(W.new(blocks), count), maximum, 0n},
      K.Step{P.build(query, length, pairs), W.initialize(W.new(blocks), count), maximum, 0n})), 1n, 0n))]

# Full-width oracle uses guarded mask access and owns a separate initial
# frontier. Unlike a trimmed band, every logical block must match exactly.
def full_reference(target: String, state: W.Updated) -> W.Updated:
  match target state:
    case SNil{} _:
      state
    case SCon{h, t} W.Updated{profile, workspace, _, _}:
      full_reference(t, W.column_reference(profile, workspace, Char.to_u32(h), V.Carry{1, 0}))

def full_finish(+length: Nat, +columns: Nat, state: W.Updated) -> K.Run:
  W.Updated{profile, workspace, _, _} = state
  K.finish(profile, workspace, 4294967295n, Word.padding(length),
    Nat.mul(Word.blocks(length), columns), columns, True{})

def full(target: String, profile: P.Profile, workspace: W.Workspace, +length: Nat, columns: Nat) -> K.Run:
  match length:
    case 0n:
      K.Run{profile, workspace, K.Stats{E.Found{columns}, 0n, 0n, 0n}}
    case 1n+p:
      full_finish(1n+p, columns, full_reference(target,
        W.Updated{profile, W.initialize(workspace, Word.blocks(1n+p)), 0, V.Carry{1, 0}}))

def metrics_of(value: K.Run) -> List<&2, E.AlignResult>:
  K.Run{_, _, stats} = value
  metrics(stats)

def run_dense(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, +threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +count = Word.blocks(length)
  List.append(&2, E.AlignResult,
    compare(count,
      Bytes.result(Dense.packed(Packed.packed(target), P.build(query, length, pairs), W.new(count), length)),
      full(target, P.build(query, length, pairs), W.new(count), length, columns)),
    List.append(&2, E.AlignResult,
      compare(count, Dense.string(target, P.build(query, length, pairs), W.new(count), length, columns),
        full(target, P.build(query, length, pairs), W.new(count), length, columns)),
      List.append(&2, E.AlignResult,
        metrics_of(reference(target, P.build(query, length, pairs), W.new(count), length, columns, threshold)),
        metrics_of(Dense.search(target, P.build(query, length, pairs), W.new(count), length, columns, threshold)))))

def dense_steps(a: W.Updated, b: W.Updated) -> Compared:
  W.Updated{ap, aw, _, _} = a
  W.Updated{bp, bw, _, _} = b
  compare_steps(K.Step{ap, aw, 0n, 0n}, K.Step{bp, bw, 0n, 0n})

def dense_columns(target: String, state: Compared) -> Bool:
  match target state:
    case SNil{} Compared{_, same, _, _}:
      same
    case SCon{+h, t} Compared{_, same, K.Step{ap, a, _, _}, K.Step{bp, b, _, _}}:
      Bool.and(same, dense_columns(t,
        dense_steps(W.column(ap, a, Char.to_u32(h), V.Carry{1, 0}),
          W.column_reference(bp, b, Char.to_u32(h), V.Carry{1, 0}))))

def run_dense_columns(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, target, E.AlignConfig{_, _, _, +pairs, _}} = job
  +length = String.length(query)
  +count = Word.blocks(length)
  [metric(Bool.pick(Nat, dense_columns(target,
    compare_steps(K.Step{P.build(query, length, pairs), W.initialize(W.new(count), count), 0n, 0n},
      K.Step{P.build(query, length, pairs), W.initialize(W.new(count), count), 0n, 0n})), 1n, 0n))]

def restarted_bytes(+length: Nat, +columns: Nat, value: Bytes.Run) -> K.Run:
  Bytes.Run{bytes, K.Run{profile, workspace, previous}} = value
  K.accumulated(previous, Bytes.result(Dense.packed(BT.Target{bytes, columns}, profile, workspace, length)))

def restarted_reference(target: String, +length: Nat, +columns: Nat, value: K.Run) -> K.Run:
  K.Run{profile, workspace, previous} = value
  K.accumulated(previous, full(target, profile, workspace, length, columns))

def run_dense_restart(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +count = Word.blocks(length)
  compare(count,
    restarted_bytes(length, columns, Bytes.attempt(packed_bytes(Packed.packed(target)),
      P.build(query, length, pairs), W.new(count), length, columns, 32n, Word.padding(length))),
    restarted_reference(target, length, columns, attempt_reference(target,
      P.build(query, length, pairs), W.new(count), length, columns, 32n, Word.padding(length))))

def run_dense_public(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, +config} = job
  E.AlignConfig{_, _, threshold, +pairs, _} = config
  +length = String.length(query)
  List.append(&2, E.AlignResult,
    metrics_of(Dense.search(target, P.build(query, length, pairs), W.new(Word.blocks(length)),
      length, String.length(target), threshold)), [M.edlib_align(query, target, config)])

def run_dense_fallback(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, +threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +count = Word.blocks(length)
  compare(count,
    Dense.choose(target, P.build(query, length, pairs), W.new(count), length, columns, threshold, False{}),
    K.search(target, P.build(query, length, pairs), W.new(count), length, columns, threshold))

def run_dense_bounds() -> List<&2, E.AlignResult>:
  [metric(Bool.pick(Nat, Dense.supported(65537n, 2147483647n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(2147483647n, 2147483647n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(2147483648n, 1n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(1n, 2147483648n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(4194304n, 2147483647n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(4194305n, 2147483647n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(2147483647n, 4194303n), 1n, 0n)),
   metric(Bool.pick(Nat, Dense.supported(2147483647n, 4194304n), 1n, 0n))]

def band_after_bytes(+length: Nat, +columns: Nat, value: Bytes.Run) -> K.Run:
  Bytes.Run{bytes, K.Run{profile, workspace, _}} = value
  Bytes.result(Bytes.attempt(bytes, profile, workspace, length, columns, 32n, Word.padding(length)))

def band_after_full(target: String, +length: Nat, columns: Nat, value: K.Run) -> K.Run:
  K.Run{profile, workspace, _} = value
  attempt_reference(target, profile, workspace, length, columns, 32n, Word.padding(length))

def run_dense_then_band(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, _, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +count = Word.blocks(length)
  compare(count,
    band_after_bytes(length, columns, Dense.packed(Packed.packed(target), P.build(query, length, pairs), W.new(count), length)),
    band_after_full(target, length, columns, full(target, P.build(query, length, pairs), W.new(count), length, columns)))

def run_choose(job: E.AlignJob, mode: U32) -> List<&2, E.AlignResult>:
  match mode:
    case 1:
      run_attempt(job)
    case 2:
      run_transitions(job)
    case 3:
      run_dense(job)
    case 4:
      run_dense_columns(job)
    case 5:
      run_dense_restart(job)
    case 6:
      run_dense_public(job)
    case 7:
      run_dense_fallback(job)
    case 8:
      run_dense_bounds()
    case 9:
      run_dense_then_band(job)
    case _:
      run(job)

def probe_mode(args: List<String>) -> U32:
  match args:
    case _ <> "attempt" <> Nil{}:
      1
    case _ <> "transitions" <> Nil{}:
      2
    case _ <> "dense" <> Nil{}:
      3
    case _ <> "dense-columns" <> Nil{}:
      4
    case _ <> "dense-restart" <> Nil{}:
      5
    case _ <> "dense-public" <> Nil{}:
      6
    case _ <> "dense-fallback" <> Nil{}:
      7
    case _ <> "dense-bounds" <> Nil{}:
      8
    case _ <> "dense-then-band" <> Nil{}:
      9
    case _:
      0

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(run_choose(job, probe_mode(args)))
