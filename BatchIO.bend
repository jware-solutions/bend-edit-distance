import Base
import ./EdlibTypes.bend as E
import ./BinaryTransport.bend as BT
import ./ByteProtocol.bend as P

# COUNT ordinary binary requests followed by COUNT ordinary binary responses.
def job(request: BT.Request) -> IO(E.AlignJob):
  match request:
    case BT.Bytes{m, t, k, f, qb, tb, eq}:
      IO.pure(E.AlignJob, E.AlignJob{P.byte_string(qb), P.byte_string(tb),
        E.AlignConfig{P.mode(m), P.task(t), P.threshold(k), P.pairs(eq), P.format(f)}})
    case _:
      IO.die(E.AlignJob, 2, "Expected a complete alignment request")

def read(count: Nat) -> IO(List<&2, E.AlignJob>):
  match count:
    case 0n:
      IO.pure(List<&2, E.AlignJob>, Nil{})
    case 1n+p:
      do IO<List<&2, E.AlignJob>>:
        request : BT.Request <- BT.read_request()
        head : E.AlignJob <- job(request)
        tail : List<&2, E.AlignJob> <- read(p)
        return head <> tail

def write(results: List<&2, E.AlignResult>) -> IO(Unit):
  match results:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case head <> tail:
      do IO<Unit>:
        BT.write_response(P.encode(head))
        write(tail)
