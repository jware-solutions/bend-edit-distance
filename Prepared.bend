import Base
import ./EdlibTypes.bend as E
import ./src/Sequence.bend as S
import ./src/BitVector.bend as V
import ./src/Profile.bend as P
import ./src/Workspace.bend as W
import ./src/SearchKernel.bend as K
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
      Prepared{query, pairs, length, Some{P.build(query, length, pairs)}, W.new(V.ceil_div(length, 32n))}
    case False{}:
      Prepared{query, pairs, length, None{}, W.new(0n)}

def prepare(+query: String, +equalities: List<&2, E.EqualityPair>) -> Prepared:
  match query:
    case SNil{}:
      Prepared{"", equalities, 0n, None{}, W.new(0n)}
    case _:
      prepare.supported(query, equalities, S.length(query), Bool.and(P.bytes(query), P.byte_pairs(equalities)))

def align.nw(+query: String, +target: String, +length: Nat, +pairs: List<&2, E.EqualityPair>,
               task: E.Task, format: E.CigarFormat, result: K.Run) -> Prepared & E.AlignResult:
  K.Run{profile, workspace, K.Stats{distance, _, _, _}} = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    M.nw_result(query, target, task, pairs, format, E.end_coordinate(S.length(target)), distance))

def align.semi(+query: String, +target: String, length: Nat, +pairs: List<&2, E.EqualityPair>,
                 +mode: E.Mode, task: E.Task, threshold: E.Threshold, format: E.CigarFormat,
                 result: K.BestRun) -> Prepared & E.AlignResult:
  K.BestRun{profile, workspace, best, _} = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    M.configured_finish(query, target, mode, task, threshold, pairs, format, best))

def align.bytes(+query: String, +target: String, +length: Nat, +pairs: List<&2, E.EqualityPair>,
                  profile: P.Profile, workspace: W.Workspace, options: Options) -> Prepared & E.AlignResult:
  match options:
    case Options{E.NW{}, task, threshold, format}:
      align.nw(query, target, length, pairs, task, format,
        K.search(target, profile, workspace, length, S.length(target), threshold))
    case Options{+mode, task, +threshold, format}:
      align.semi(query, target, length, pairs, mode, task, threshold, format,
        K.best(target, profile, workspace, length, M.semiglobal_maximum(threshold, length), mode))

def align.supported(+query: String, +target: String, +length: Nat, +pairs: List<&2, E.EqualityPair>,
                      profile: P.Profile, workspace: W.Workspace, options: Options,
                      compact: Bool) -> Prepared & E.AlignResult:
  match compact:
    case True{}:
      align.bytes(query, target, length, pairs, profile, workspace, options)
    case False{}:
      (Prepared{query, pairs, length, Some{profile}, workspace}, M.edlib_align(query, target, config(options, pairs)))

def align(prepared: Prepared, +target: String, +options: Options) -> Prepared & E.AlignResult:
  match prepared target:
    case Prepared{SNil{}, +pairs, length, profile, workspace} _:
      (Prepared{"", pairs, length, profile, workspace}, A.empty_result("", target, config(options, pairs)))
    case Prepared{+query, +pairs, length, profile, workspace} SNil{}:
      (Prepared{query, pairs, length, profile, workspace}, A.empty_result(query, "", config(options, pairs)))
    case Prepared{+query, +pairs, +length, None{}, workspace} _:
      (Prepared{query, pairs, length, None{}, workspace}, M.edlib_align(query, target, config(options, pairs)))
    case Prepared{query, pairs, length, Some{profile}, workspace} _:
      align.supported(query, target, length, pairs, profile, workspace, options, P.bytes(target))

def clone.profile(+query: String, +pairs: List<&2, E.EqualityPair>, +length: Nat,
                     workspace: W.Workspace, result: P.Profile & P.Profile) -> Prepared & Prepared:
  (profile, other) = result
  (Prepared{query, pairs, length, Some{profile}, workspace},
    Prepared{query, pairs, length, Some{other}, W.new(V.ceil_div(length, 32n))})

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

# Buffer/term payload bytes, excluding allocator metadata and shared refcounts.
# The worker applies a separate conservative admission limit to wire inputs.
def retained_bytes(prepared: Prepared) -> Prepared & Nat:
  match prepared:
    case Prepared{+query, +pairs, +length, None{}, workspace}:
      (Prepared{query, pairs, length, None{}, workspace},
        Nat.add(Nat.mul(length, 16n), Nat.mul(List.length(&2, E.EqualityPair, pairs), 32n)))
    case Prepared{query, +pairs, +length, Some{profile}, workspace}:
      retained.profile(query, pairs, length, workspace,
        Nat.add(Nat.add(Nat.mul(length, 16n), Nat.mul(List.length(&2, E.EqualityPair, pairs), 32n)),
          Nat.mul(32n, Nat.pow(2n, P.depth(V.ceil_div(length, 32n))))), P.retained_bytes(profile))

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
