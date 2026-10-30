import Base
import ../EdlibTypes.bend as E
import ../src/Transport.bend as T
import ../src/ByteProtocol.bend as P
import ./response_fields.bend as F

def pure(values: List<&2, E.AlignResult>) -> IO(Unit):
  match values:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        T.write_response(P.encode(head))
        pure(tail)

def main() -> IO(Unit):
  +values = F.fixtures()
  do IO<Unit>:
    T.write_batch(values)
    T.write_batch(Nil{})
    T.write_result(E.not_found())
    pure(values)
    T.write_batch([E.not_found()])
    T.write_batch(values)
