import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ../src/PreparedBytes.bend as PB
import ../src/ByteTarget.bend as BT
import ../src/Profile.bend as P
import ../src/Transport.bend as T

def packed.byte(+index: U32, code: U32, value: Array<U32> & U32) -> Array<U32>:
  (bytes, word) = value
  bytes[U32.shrn(index, BT.log_cell_bytes())] <- U32.or(word,
    U32.shln(code, U32.to_nat(U32.shln(U32.and(index, 3), 3n))))

def packed.scan(sequence: String, +index: U32, bytes: Array<U32>) -> Array<U32>:
  match sequence:
    case SNil{}:
      bytes
    case SCon{symbol, tail}:
      packed.scan(tail, U32.inc(index), packed.byte(index, Char.to_u32(symbol),
        bytes[U32.shrn(index, BT.log_cell_bytes())]))

def packed(+sequence: String) -> BT.Target:
  +length = String.length(sequence)
  BT.Target{packed.scan(sequence, 0, Array.new(U32, P.depth(Nat.div(Nat.add(length, 3n), BT.cell_bytes())), 0)), length}

def compare(+query: String, +target: String, +pairs: List<&2, E.EqualityPair>) -> List<&2, E.AlignResult>:
  [Q.result(PB.align(Q.prepare(query, pairs), packed(target))),
   Q.result(Q.align(Q.prepare(query, pairs), target, Q.default_options()))]

def reused(value: Q.Prepared & E.AlignResult) -> List<&2, E.AlignResult>:
  (prepared, result) = value
  [result, Q.result(PB.align(prepared, BT.Target{[65 : U32*1n], 1n}))]

def bounds() -> List<&2, E.AlignResult>:
  List.append(&2, E.AlignResult,
    reused(PB.align(Q.prepare("A", Nil{}), BT.Target{[65 : U32*1n], 5n})),
    reused(PB.align(Q.prepare("A", Nil{}), BT.Target{[65 : U32*1n], 2147483648n})))

def run(value: E.AlignJob, kind: String) -> List<&2, E.AlignResult>:
  E.AlignJob{query, target, E.AlignConfig{_, _, _, pairs, _}} = value
  match kind:
    case "bounds":
      bounds()
    case "query":
      compare(SCon{Chr{256}, query}, target, pairs)
    case "pairs":
      compare(query, target, E.EqualityPair{Chr{256}, 'A'} <> pairs)
    case _:
      compare(query, target, pairs)

def args(values: List<String>, job: E.AlignJob) -> List<&2, E.AlignResult>:
  match values:
    case _ <> kind <> Nil{}:
      run(job, kind)
    case _:
      run(job, "byte")

def main() -> IO(Unit):
  do IO<Unit>:
    values : List<String> <- IO.args()
    request : T.Request <- T.read_request()
    job : E.AlignJob <- T.job(request)
    T.write_batch(args(values, job))
