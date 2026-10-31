import ./src/Word.bend as Word
import Base
import ./EdlibTypes.bend as E
import ./src/Sequence.bend as S
import ./src/BitVector.bend as V
import ./src/Profile.bend as P
import ./src/Workspace.bend as W
import ./src/SearchKernel.bend as K
import ./src/RetryHint.bend as Hint
import ./src/SingleWord.bend as SW
import ./src/TwoWord.bend as TW
import ./src/Myers.bend as M
import ./src/Alignment.bend as A

# Query, equalities, compact layout and U32 word width are fixed. Mutable
# search state has separate ownership and is reset for each target/attempt.
type Prepared is Type:
  Prepared{query: String, equalities: List<&2, E.EqualityPair>, length: Nat,
           profile: Maybe<&1, P.Profile>, workspace: W.Workspace}

type Options is Data:
  Options{mode: E.Mode, task: E.Task, threshold: E.Threshold, format: E.CigarFormat}

def default_options() -> Options:
  Options{E.NW{}, E.Distance{}, E.Unlimited{}, E.Extended{}}

def config(options: Options, equalities: List<&2, E.EqualityPair>) -> E.AlignConfig:
  Options{mode, task, threshold, format} = options
  E.AlignConfig{mode, task, threshold, equalities, format}

def prepare.supported(+query: String, +pairs: List<&2, E.EqualityPair>, +length: Nat,
                        compact: Bool) -> Prepared:
  match compact:
    case True{}:
      Prepared{query, pairs, length, Some{P.build(query, length, pairs)}, W.new(Word.blocks(length))}
    case False{}:
      Prepared{query, pairs, length, None{}, W.new(0n)}

def prepare(+query: String, +equalities: List<&2, E.EqualityPair>) -> Prepared:
  match query:
    case SNil{}:
      Prepared{"", equalities, 0n, None{}, W.new(0n)}
    case _:
      prepare.supported(query, equalities, S.length(query), Bool.and(P.bytes(query), P.byte_pairs(equalities)))

def align.nw(+query: String, +target: String, +length: Nat, columns: Nat,
               +pairs: List<&2, E.EqualityPair>, task: E.Task, format: E.CigarFormat,
               result: K.Run) -> Prepared & E.AlignResult:
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    M.nw_result(query, target, task, pairs, format, E.end_coordinate(columns), distance))

def align.nw_metadata(query: String, +length: Nat, columns: Nat, pairs: List<&2, E.EqualityPair>,
                        task: E.Task, format: E.CigarFormat, result: K.Run) -> Prepared & E.AlignResult:
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    M.nw_result("", "", task, Nil{}, format, E.end_coordinate(columns), distance))

def align.semi(+query: String, +target: String, length: Nat, +pairs: List<&2, E.EqualityPair>,
                 +mode: E.Mode, task: E.Task, threshold: E.Threshold, format: E.CigarFormat,
                 result: K.BestRun) -> Prepared & E.AlignResult:
  K.BestRun{profile, workspace, best, _} = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    M.configured_finish(query, target, mode, task, threshold, pairs, format, best))

def run_nw.result(workspace: W.Workspace, +columns: Nat, result: SW.Run) -> K.Run:
  SW.Run{profile, block, distance} = result
  K.Run{profile, W.put(W.bounds(workspace, 0, 1), 0, block), K.Stats{distance, columns, columns, 1n}}

# The scalar loop is valid only for a complete, nonempty query word.
# Guard logical shapes before the final write into the wrapping array.
def single_word(+length: Nat, stride: U32, blocks: U32, capacity: U32) -> Bool:
  Bool.and(Bool.and(Nat.is_gt(length, 0n), Nat.is_le(length, Word.width())),
    Bool.and(U32.is_eq(stride, 1), Bool.and(U32.is_eq(blocks, 1), U32.is_eq(capacity, 1))))

def two_word(+length: Nat, stride: U32, blocks: U32, capacity: U32) -> Bool:
  Bool.and(Bool.and(Nat.is_gt(length, Word.width()), Nat.is_le(length, Nat.mul(Word.width(), 2n))),
    Bool.and(U32.is_eq(stride, 2), Bool.and(U32.is_eq(blocks, 2), U32.is_eq(capacity, 2))))

def run_nw.two.result(workspace: W.Workspace, +columns: Nat, result: TW.Run) -> K.Run:
  TW.Run{profile, first, second, distance} = result
  K.Run{profile, W.put(W.put(W.bounds(workspace, 0, 2), 0, first), 1, second),
    K.Stats{distance, Nat.mul(columns, 2n), columns, 1n}}

def run_nw.two(target: String, profile: P.Profile, workspace: W.Workspace,
                  length: Nat, columns: Nat, suitable: Bool) -> K.Run:
  match suitable:
    case True{}:
      run_nw.two.result(workspace, columns, TW.run(target, profile, Word.padding(length)))
    case False{}:
      Hint.search(target, profile, workspace, length, columns)

def run_nw.small(target: String, profile: P.Profile, workspace: W.Workspace,
                    +length: Nat, columns: Nat, stride: U32, blocks: U32, capacity: U32, one: Bool) -> K.Run:
  match one:
    case True{}:
      run_nw.result(workspace, columns, SW.run(target, profile, Word.padding(length)))
    case False{}:
      run_nw.two(target, profile, workspace, length, columns,
        two_word(length, stride, blocks, capacity))

def run_nw.shaped(profile: P.Profile, workspace: W.Workspace, target: String, +length: Nat,
                     columns: Nat) -> K.Run:
  P.Profile{lookup, masks, +stride, rows, +blocks, used} = profile
  W.Workspace{data, +capacity, first, last} = workspace
  run_nw.small(target, P.Profile{lookup, masks, stride, rows, blocks, used},
    W.Workspace{data, capacity, first, last}, length, columns, stride, blocks, capacity,
    single_word(length, stride, blocks, capacity))

def run_nw(target: String, profile: P.Profile, workspace: W.Workspace, length: Nat,
              columns: Nat, threshold: E.Threshold) -> K.Run:
  match threshold:
    case E.Unlimited{}:
      run_nw.shaped(profile, workspace, target, length, columns)
    case _:
      K.search(target, profile, workspace, length, columns, threshold)

def align.bytes(+query: String, +target: String, +length: Nat, +columns: Nat,
                  +pairs: List<&2, E.EqualityPair>, profile: P.Profile, workspace: W.Workspace,
                  options: Options) -> Prepared & E.AlignResult:
  match options:
    case Options{E.NW{}, E.Distance{}, threshold, format}:
      align.nw_metadata(query, length, columns, pairs, E.Distance{}, format,
        run_nw(target, profile, workspace, length, columns, threshold))
    case Options{E.NW{}, E.Locations{}, threshold, format}:
      align.nw_metadata(query, length, columns, pairs, E.Locations{}, format,
        run_nw(target, profile, workspace, length, columns, threshold))
    case Options{E.NW{}, E.Path{}, threshold, format}:
      align.nw(query, target, length, columns, pairs, E.Path{}, format,
        run_nw(target, profile, workspace, length, columns, threshold))
    case Options{+mode, task, +threshold, format}:
      align.semi(query, target, length, pairs, mode, task, threshold, format,
        K.best(target, profile, workspace, length, M.semiglobal_maximum(threshold, length), mode))

def align.supported(+query: String, +target: String, +length: Nat, columns: Nat,
                      +pairs: List<&2, E.EqualityPair>, profile: P.Profile, workspace: W.Workspace,
                      options: Options, compact: Bool) -> Prepared & E.AlignResult:
  match compact:
    case True{}:
      align.bytes(query, target, length, columns, pairs, profile, workspace, options)
    case False{}:
      (Prepared{query, pairs, length, Some{profile}, workspace},
        M.edlib_align_sized(query, target, config(options, pairs), length, columns))

def align.empty_query(+columns: Nat, options: Options) -> E.AlignResult:
  match options:
    case Options{E.NW{}, _, _, _}:
      E.distance_result(columns, E.end_coordinate(columns), True{})
    case _:
      E.distance_result(0n, E.BeforeStart{}, True{})

def align.known(query: String, +target: String, length: Nat, columns: Nat,
                  pairs: List<&2, E.EqualityPair>, profile: P.Profile, workspace: W.Workspace,
                  options: Options, known_bytes: Bool) -> Prepared & E.AlignResult:
  match known_bytes:
    case True{}:
      align.bytes(query, target, length, columns, pairs, profile, workspace, options)
    case False{}:
      align.supported(query, target, length, columns, pairs, profile, workspace, options, P.bytes(target))

# Internal batch entry: target lengths are computed before execution forks.
def align_sized_known(prepared: Prepared, +target: String, options: Options, columns: Nat, known_bytes: Bool) -> Prepared & E.AlignResult:
  match prepared target:
    case Prepared{SNil{}, pairs, length, profile, workspace} _:
      (Prepared{"", pairs, length, profile, workspace}, align.empty_query(columns, options))
    case Prepared{query, pairs, +length, profile, workspace} SNil{}:
      (Prepared{query, pairs, length, profile, workspace}, E.distance_result(length, E.BeforeStart{}, True{}))
    case Prepared{+query, +pairs, +length, None{}, workspace} _:
      (Prepared{query, pairs, length, None{}, workspace},
        M.edlib_align_sized(query, target, config(options, pairs), length, columns))
    case Prepared{query, pairs, length, Some{profile}, workspace} _:
      align.known(query, target, length, columns, pairs, profile, workspace, options, known_bytes)

def align_sized(prepared: Prepared, target: String, options: Options, columns: Nat) -> Prepared & E.AlignResult:
  align_sized_known(prepared, target, options, columns, False{})

def align_cached(prepared: Prepared, +target: String, options: Options) -> Prepared & E.AlignResult:
  align_sized(prepared, target, options, String.length(target))

def align(prepared: Prepared, +target: String, +options: Options) -> Prepared & E.AlignResult:
  match prepared target:
    case Prepared{+query, +pairs, length, profile, workspace} SNil{}:
      (Prepared{query, pairs, length, profile, workspace}, A.empty_result(query, "", config(options, pairs)))
    case _ _:
      align_cached(prepared, target, options)

def clone.profile(+query: String, +pairs: List<&2, E.EqualityPair>, +length: Nat,
                     workspace: W.Workspace, result: P.Profile & P.Profile) -> Prepared & Prepared:
  (profile, other) = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    Prepared{query, pairs, length, Some{other}, W.new(Word.blocks(length))})

# Explicit clones give concurrent shards separate masks and mutable storage.
def clone(prepared: Prepared) -> Prepared & Prepared:
  match prepared:
    case Prepared{+query, +pairs, +length, None{}, workspace}:
      (Prepared{query, pairs, length, None{}, workspace}, Prepared{query, pairs, length, None{}, W.new(0n)})
    case Prepared{query, pairs, length, Some{profile}, workspace}:
      clone.profile(query, pairs, length, workspace, P.clone(profile))

def retained.profile(query: String, pairs: List<&2, E.EqualityPair>, length: Nat,
                        workspace: W.Workspace, +other: Nat, result: P.Profile & Nat) -> Prepared & Nat:
  (profile, bytes) = result
  (Prepared{query, pairs, length, Some{profile}, workspace}, Nat.add(other, bytes))

# Buffer bytes plus sequence/equality nodes. The worker adds a conservative
# allowance for wrapper records, allocator metadata and shared refcounts.
def retained_bytes(prepared: Prepared) -> Prepared & Nat:
  match prepared:
    case Prepared{+query, +pairs, +length, None{}, workspace}:
      (Prepared{query, pairs, length, None{}, workspace},
        Nat.add(W.storage_bytes(0n),
          Nat.add(Nat.mul(length, 16n), Nat.mul(List.length(&2, E.EqualityPair, pairs), 32n))))
    case Prepared{query, +pairs, +length, Some{profile}, workspace}:
      retained.profile(query, pairs, length, workspace,
        Nat.add(Nat.add(Nat.mul(length, 16n), Nat.mul(List.length(&2, E.EqualityPair, pairs), 32n)),
          W.storage_bytes(Word.blocks(length))), P.retained_bytes(profile))

type BatchState is Type:
  BatchState{prepared: Prepared, results: List<&2, E.AlignResult>}

def batch.updated(results: List<&2, E.AlignResult>, result: Prepared & E.AlignResult) -> BatchState:
  (prepared, value) = result
  BatchState{prepared, value <> results}

def batch(targets: List<&2, String>, +options: Options, state: BatchState) -> Prepared & List<&2, E.AlignResult>:
  match targets state:
    case Nil{} BatchState{prepared, results}:
      (prepared, List.reverse(&2, E.AlignResult, results))
    case target <> tail BatchState{prepared, results}:
      batch(tail, options, batch.updated(results, align(prepared, target, options)))

def align_batch(prepared: Prepared, targets: List<&2, String>, options: Options) -> Prepared & List<&2, E.AlignResult>:
  batch(targets, options, BatchState{prepared, Nil{}})

def result(value: Prepared & E.AlignResult) -> E.AlignResult:
  (_, aligned) = value
  aligned

def empty_target(prepared: Prepared, options: Options) -> E.AlignResult:
  Prepared{query, pairs, _, _, _} = prepared
  A.empty_result(query, "", config(options, pairs))

def batch_cached(targets: List<&2, String>, +options: Options, state: BatchState) -> Prepared & List<&2, E.AlignResult>:
  match targets state:
    case Nil{} BatchState{prepared, results}:
      (prepared, List.reverse(&2, E.AlignResult, results))
    case target <> tail BatchState{prepared, results}:
      batch_cached(tail, options, batch.updated(results, align_cached(prepared, target, options)))

def align_batch_cached(prepared: Prepared, targets: List<&2, String>, options: Options) -> Prepared & List<&2, E.AlignResult>:
  batch_cached(targets, options, BatchState{prepared, Nil{}})
