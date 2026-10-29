import Base
import ../EdlibTypes.bend as E
import ../src/Alignment.bend as A
import ../src/DistanceDP.bend as DP
import ../src/Reconstruction.bend as R
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
    case _:
      IO.die(Unit, 2, "Expected dp|indexed|divide|auto --worker")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
