import Base
import ../EdlibTypes.bend as E
import ../src/Transport.bend as T
import ../src/ByteProtocol.bend as P

def both(+value: E.AlignResult) -> IO(Unit):
  do IO<Unit>:
    T.write_result(value)
    T.write_response(P.encode(value))

def aliased(+ends: List<&2, E.Coordinate>, operations: List<&2, E.Operation>, cigar: String) -> E.AlignResult:
  E.AlignResult{E.Ok{}, E.Found{4n}, ends, Some{ends}, Some{operations}, Some{cigar}}

def text(count: Nat, value: String) -> String:
  match count:
    case 0n:
      value
    case 1n+p:
      text(p, SCon{'X', value})

def fixtures() -> List<&2, E.AlignResult>:
  [E.not_found(),
   E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}},
   E.AlignResult{E.Ok{}, E.Found{0n}, Nil{}, Some{Nil{}}, Some{Nil{}}, Some{""}},
   E.AlignResult{E.Ok{}, E.Found{4294967295n}, [E.BeforeStart{}, E.Position{4294967295n}], None{}, None{}, None{}},
   aliased([E.BeforeStart{}, E.Position{0n}, E.Position{128n}, E.Position{2147483647n}],
     [E.Match{}, E.Insert{}, E.Delete{}, E.Mismatch{}], "1=1I1D1X"),
   aliased(Nil{}, Nil{}, SCon{Chr{255}, SCon{Chr{0}, SCon{Chr{128}, ""}}}),
   aliased(List.replicate(E.Coordinate, 8193n, E.Position{128n}), Nil{}, ""),
   aliased(Nil{}, List.replicate(E.Operation, 8193n, E.Mismatch{}),
     text(8193n, ""))]

def emit(values: List<&2, E.AlignResult>) -> IO(Unit):
  match values:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        both(head)
        emit(tail)

def main() -> IO(Unit):
  emit(fixtures())
