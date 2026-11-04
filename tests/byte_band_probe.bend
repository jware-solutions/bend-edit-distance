import Base
import ../EdlibTypes.bend as E
import ../src/ByteKernel.bend as Bytes
import ../src/RetryHint.bend as Hint
import ../src/SearchKernel.bend as K
import ../src/Profile.bend as P
import ../src/Workspace.bend as W
import ../src/Word.bend as Word
import ../src/Transport.bend as T
import ./prepared_bytes_probe.bend as Packed

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

def reference(target: String, profile: P.Profile, workspace: W.Workspace, length: Nat,
                  columns: Nat, threshold: E.Threshold) -> K.Run:
  match threshold:
    case E.Unlimited{}:
      Hint.search(target, profile, workspace, length, columns)
    case _:
      K.search(target, profile, workspace, length, columns, threshold)

def run(job: E.AlignJob) -> List<&2, E.AlignResult>:
  E.AlignJob{+query, +target, E.AlignConfig{_, _, +threshold, +pairs, _}} = job
  +length = String.length(query)
  +columns = String.length(target)
  +blocks = Word.blocks(length)
  compare(blocks,
    Bytes.search(Packed.packed(target), P.build(query, length, pairs), W.new(blocks), length, threshold),
    reference(target, P.build(query, length, pairs), W.new(blocks), length, columns, threshold))

def main() -> IO(Unit):
  do IO<Unit>:
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(run(job))
