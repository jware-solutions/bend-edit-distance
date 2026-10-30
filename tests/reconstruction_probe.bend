import Base
import ../EdlibTypes.bend as E
import ../src/Alignment.bend as A
import ../src/DistanceDP.bend as DP
import ../src/Reconstruction.bend as R
import ../src/SmallPath.bend as S
import ../src/Transport.bend as BT

# Exercise full DP and forced splits independently of public dispatch and
# Myers. Empty inputs here deliberately return paths to test base cases.
def probe_align(~reconstruct: @+query:String -> @+target:String -> List<&2, E.EqualityPair> -> List<&2, E.Operation>,
                  +query: String, +target: String, config: E.AlignConfig) -> E.AlignResult:
  match config:
    case E.AlignConfig{_, _, _, +pairs, format}:
      A.path_result(U32.from_nat(DP.distance_with_equalities(query, target, pairs)),
        [A.Location{E.end_coordinate(String.length(target)), 0n}],
        reconstruct(query, target, pairs), format)

def divided(+query: String, +target: String, pairs: List<&2, E.EqualityPair>) -> List<&2, E.Operation>:
  +qn +tn = String.length(query) String.length(target)
  R.divide(qn, query, target, qn, tn, pairs, False{})

def dp_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  probe_align(~R.dp, query, target, config)

def indexed_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  probe_align(~R.trace_path, query, target, config)

def divided_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  probe_align(~divided, query, target, config)

def auto_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  probe_align(~R.reconstruct, query, target, config)

def known(+query: String, +target: String, pairs: List<&2, E.EqualityPair>) -> List<&2, E.Operation>:
  +equalities = pairs
  R.reconstruct_known(query, target, equalities, DP.distance_with_equalities(query, target, equalities))

def known_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  probe_align(~known, query, target, config)

def bounded_result(query: String, +target: String, pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
                     result: S.Search) -> E.AlignResult:
  match result:
    case S.NotFound{}:
      E.not_found()
    case S.Found{cost, trail}:
      A.path_validate(query, target, pairs, U32.from_nat(cost),
        [A.Location{E.end_coordinate(String.length(target)), 0n}], format, S.operations(trail, Nil{}), True{})

def bounded(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
               maximum: Nat) -> E.AlignResult:
  bounded_result(query, target, pairs, format, S.search(query, target, pairs, maximum))

def bounded_align(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match config:
    case E.AlignConfig{_, _, E.MaxDistance{maximum}, pairs, format}:
      bounded(query, target, pairs, format, maximum)
    case E.AlignConfig{_, _, _, pairs, format}:
      +q = query
      +t = target
      bounded(q, t, pairs, format, Nat.max(String.length(q), String.length(t)))

def auto_generic(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  auto_align(SCon{Chr{256}, query}, SCon{Chr{256}, target}, config)

def known_generic(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  known_align(SCon{Chr{256}, query}, SCon{Chr{256}, target}, config)

def auto_generic_pairs(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  E.AlignConfig{mode, task, threshold, pairs, format} = config
  auto_align(query, target, E.AlignConfig{mode, task, threshold, E.EqualityPair{Chr{256}, 'N'} <> pairs, format})

def known_generic_pairs(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  E.AlignConfig{mode, task, threshold, pairs, format} = config
  known_align(query, target, E.AlignConfig{mode, task, threshold, E.EqualityPair{Chr{256}, 'N'} <> pairs, format})

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "dp" <> "--worker" <> Nil{}:
      BT.serve(~dp_align)
    case _ <> "indexed" <> "--worker" <> Nil{}:
      BT.serve(~indexed_align)
    case _ <> "divide" <> "--worker" <> Nil{}:
      BT.serve(~divided_align)
    case _ <> "auto" <> "--worker" <> Nil{}:
      BT.serve(~auto_align)
    case _ <> "known" <> "--worker" <> Nil{}:
      BT.serve(~known_align)
    case _ <> "bounded" <> "--worker" <> Nil{}:
      BT.serve(~bounded_align)
    case _ <> "auto-generic" <> "--worker" <> Nil{}:
      BT.serve(~auto_generic)
    case _ <> "known-generic" <> "--worker" <> Nil{}:
      BT.serve(~known_generic)
    case _ <> "auto-generic-pairs" <> "--worker" <> Nil{}:
      BT.serve(~auto_generic_pairs)
    case _ <> "known-generic-pairs" <> "--worker" <> Nil{}:
      BT.serve(~known_generic_pairs)
    case _:
      IO.die(Unit, 2, "Expected a reconstruction probe algorithm and --worker")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
