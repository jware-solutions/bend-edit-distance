import Base
import ../main.bend as M
import ../Cli.bend as CLI
import ../EdlibTypes.bend as E
import ../lib.bend as L
import ./timer.bend as T

type Inputs is Data:
  Inputs{query: String, target: String, length: Nat, target_length: Nat, depth: Nat}

def orient(q: String, t: String, qn: Nat, tn: Nat, shorter: Bool, depth: Nat) -> Inputs:
  match shorter:
    case True{}:
      Inputs{q, t, qn, tn, depth}
    case False{}:
      Inputs{t, q, tn, qn, depth}

def prepare_inputs(mode: String, q: String, t: String, +qn: Nat, +tn: Nat,
                   depth: Nat) -> Inputs:
  match mode:
    case "full":
      Inputs{q, t, qn, tn, depth}
    case _:
      orient(q, t, qn, tn, Nat.is_le(qn, tn), depth)

def prepare(mode: String, q: String, t: String, depth: Nat,
            status: CLI.InputStatus) -> IO(Inputs):
  match status:
    case CLI.Supported{}:
      +query = q
      +target = t
      +qn +tn = String.length(query) String.length(target)
      IO.pure(Inputs, prepare_inputs(mode, query, target, qn, tn, depth))
    case _:
      IO.die(Inputs, 2, "Unsupported benchmark input")

def checksum(results: List<&2, E.AlignResult>) -> Nat:
  match results:
    case Nil{}:
      0n
    case E.AlignResult{_, distance, _, _, _, _} <> tail:
      Nat.add(M.found_value(distance), checksum(tail))

# Homogeneous inputs exercise the public CPU batch API. Work includes job-list
# construction, estimation, planning, per-job alignment and result ordering.
def full(depth: Nat, query: String, target: String) -> Nat:
  checksum(L.align_batch(List.replicate(E.AlignJob, Nat.pow(2n, depth),
    E.AlignJob{query, target, E.default_config()})))

def aligned(+depth: Nat, +target: String, +profiles: List<&2, M.Peq>,
            +length: Nat, +target_length: Nat, +count: Nat) -> Nat:
  match depth count:
    case 0n 0n:
      target_length
    case 0n _:
      M.found_value(M.search_distance(M.search_profiles(target, profiles, length,
        target_length, E.Unlimited{})))
    case 1n+p _:
      left right = aligned(p, target, profiles, length, target_length, count) aligned(p, target, profiles, length, target_length, count)
      Nat.add(left, right)

# Traverse the full profile (not the active band), without block updates.
# The scan control omits only peq_get; neither control is an alignment time.
def lookup_word(profile: M.Peq, +code: U32, tree: Bool) -> U32:
  match tree:
    case True{}:
      M.peq_get(profile, code, U32.is_ne(U32.and(code, 1), 0))
    case False{}:
      code

def lookup_column(profiles: List<&2, M.Peq>, +code: U32, +tree: Bool) -> U32:
  match profiles:
    case Nil{}:
      0
    case profile <> tail:
      U32.add(lookup_word(profile, code, tree), lookup_column(tail, code, tree))

def lookup_target(target: String, +profiles: List<&2, M.Peq>, +tree: Bool) -> U32:
  match target:
    case SNil{}:
      0
    case SCon{h, t}:
      U32.add(lookup_column(profiles, Char.to_u32(h), tree), lookup_target(t, profiles, tree))

def lookups(+depth: Nat, +target: String, +profiles: List<&2, M.Peq>, +tree: Bool) -> U32:
  match depth:
    case 0n:
      lookup_target(target, profiles, tree)
    case 1n+p:
      left right = lookups(p, target, profiles, tree) lookups(p, target, profiles, tree)
      U32.add(left, right)

def prepared_run(mode: String, depth: Nat, target: String,
                 +profiles: List<&2, M.Peq>, length: Nat, target_length: Nat, count: Nat) -> IO(Unit):
  match mode:
    case "prepared":
      do IO<Unit>:
        sum : Nat <- T.mark(Nat, 3, aligned(depth, target, profiles, length, target_length, count))
        T.release(List<&2, M.Peq>, profiles)
        T.finish(sum)
    case "lookup":
      do IO<Unit>:
        sum : U32 <- T.mark(U32, 3, lookups(depth, target, profiles, True{}))
        T.release(List<&2, M.Peq>, profiles)
        T.finish(U32.to_nat(sum))
    case "scan":
      do IO<Unit>:
        sum : U32 <- T.mark(U32, 3, lookups(depth, target, profiles, False{}))
        T.release(List<&2, M.Peq>, profiles)
        T.finish(U32.to_nat(sum))
    case _:
      IO.die(Unit, 2, "Expected full, prepared, lookup or scan")

def prepared(mode: String, inputs: Inputs) -> IO(Unit):
  match inputs:
    case Inputs{query, +target, +length, target_length, depth}:
      +count = M.ceil_div(length, 32n)
      do IO<Unit>:
        profiles : List<&2, M.Peq> <- T.mark(List<&2, M.Peq>, 2, M.build_peq(count, query, Nil{}))
        prepared_run(mode, depth, target, profiles, length, target_length, count)

def compute(mode: String, +inputs: Inputs) -> IO(Unit):
  match mode inputs:
    case "full" Inputs{query, target, _, _, depth}:
      do IO<Unit>:
        sum : Nat <- T.mark(Nat, 3, full(depth, query, target))
        T.finish(sum)
    case _ _:
      prepared(mode, inputs)

def parsed_bound(+mode: String, +query: String, +target: String, depth: Nat, bounded: Bool) -> IO(Unit):
  match bounded:
    case True{}:
      do IO<Unit>:
        checked : Inputs <- prepare(mode, query, target, depth, CLI.validate(query, target))
        inputs : Inputs <- T.mark(Inputs, 1, checked)
        compute(mode, inputs)
    case False{}:
      IO.die(Unit, 2, "Benchmark depth must be 1..10")

def parsed(mode: String, +query: String, +target: String, depth: Maybe<&2, Nat>) -> IO(Unit):
  match depth:
    case Some{0n}:
      IO.die(Unit, 2, "Benchmark depth must be 1..10 (batch size is 2^(depth-1))")
    case Some{1n+p}:
      +depth = p
      parsed_bound(mode, query, target, depth, Nat.is_lt(depth, 10n))
    case None{}:
      IO.die(Unit, 2, "Invalid benchmark depth")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> mode <> depth <> query <> target <> Nil{}:
      parsed(mode, query, target, Nat.read(depth))
    case _:
      IO.die(Unit, 2, "Expected MODE DEPTH QUERY TARGET")

def main() -> IO(Unit):
  do IO<Unit>:
    T.start()
    args : List<String> <- IO.args()
    moved : List<String> <- T.mark(List<String>, 0, args)
    run(moved)
