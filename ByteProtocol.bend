import Base
import ./EdlibTypes.bend as E

def byte_string(bytes: List<U32>) -> String:
  match bytes:
    case Nil{}:
      ""
    case h <> t:
      SCon{Chr{h}, byte_string(t)}

def pairs(bytes: List<U32>) -> List<&2, E.EqualityPair>:
  match bytes:
    case first <> second <> tail:
      E.EqualityPair{Chr{first}, Chr{second}} <> pairs(tail)
    case _:
      Nil{}

def mode(value: U32) -> E.Mode:
  match value:
    case 0:
      E.NW{}
    case 1:
      E.SHW{}
    case _:
      E.HW{}

def task(value: U32) -> E.Task:
  match value:
    case 0:
      E.Distance{}
    case 1:
      E.Locations{}
    case _:
      E.Path{}

def threshold_signed(value: U32, negative: Bool) -> E.Threshold:
  match negative:
    case True{}:
      E.Unlimited{}
    case False{}:
      E.MaxDistance{U32.to_nat(value)}

def threshold(+value: U32) -> E.Threshold:
  threshold_signed(value, U32.is_ge(value, 2147483648))

def format(value: U32) -> E.CigarFormat:
  match value:
    case 0:
      E.Standard{}
    case _:
      E.Extended{}

def u32_bytes(+value: U32) -> List<U32>:
  [U32.and(value, 255), U32.and(U32.shrn(value, 8n), 255),
   U32.and(U32.shrn(value, 16n), 255), U32.shrn(value, 24n)]

def distance_value(value: E.EditDistance) -> U32:
  match value:
    case E.NotFound{}:
      4294967295
    case E.Found{n}:
      U32.from_nat(n)

def coordinate_value(value: E.Coordinate) -> U32:
  match value:
    case E.BeforeStart{}:
      4294967295
    case E.Position{n}:
      U32.from_nat(n)

def status_value(value: E.Status) -> U32:
  match value:
    case E.Ok{}:
      0
    case E.Error{}:
      1

def operation_value(value: E.Operation) -> U32:
  match value:
    case E.Match{}:
      0
    case E.Insert{}:
      1
    case E.Delete{}:
      2
    case E.Mismatch{}:
      3

def locations(values: List<&2, E.Coordinate>) -> List<U32>:
  match values:
    case Nil{}:
      Nil{}
    case h <> t:
      List.append(&1, U32, u32_bytes(coordinate_value(h)), locations(t))

def starts(value: Maybe<&2, List<&2, E.Coordinate>>) -> U32 & List<U32>:
  match value:
    case None{}:
      (4294967295, Nil{})
    case Some{+values}:
      (U32.from_nat(List.length(&2, E.Coordinate, values)), locations(values))

def operation_bytes(values: List<&2, E.Operation>) -> List<U32>:
  match values:
    case Nil{}:
      Nil{}
    case h <> t:
      operation_value(h) <> operation_bytes(t)

def operations(value: Maybe<&2, List<&2, E.Operation>>) -> U32 & List<U32>:
  match value:
    case None{}:
      (4294967295, Nil{})
    case Some{+values}:
      (U32.from_nat(List.length(&2, E.Operation, values)), operation_bytes(values))

def cigar_bytes(value: String) -> List<U32>:
  match value:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      Char.to_u32(h) <> cigar_bytes(t)

def cigar(value: Maybe<&2, String>) -> U32 & List<U32>:
  match value:
    case None{}:
      (4294967295, Nil{})
    case Some{+value}:
      (U32.from_nat(String.length(value)), cigar_bytes(value))

def join(parts: List<List<U32>>) -> List<U32>:
  match parts:
    case Nil{}:
      Nil{}
    case h <> t:
      List.append(&1, U32, h, join(t))

def encode_parts(s: U32, d: U32, +ends: List<&2, E.Coordinate>,
                 parts: (U32 & List<U32>) & ((U32 & List<U32>) & (U32 & List<U32>))) -> List<U32>:
  match parts:
    case ((sn, sb), ((on, ob), (cn, cb))):
      join([[66, 69, 82, 49], u32_bytes(s), u32_bytes(d),
        u32_bytes(U32.from_nat(List.length(&2, E.Coordinate, ends))),
        u32_bytes(sn), u32_bytes(on), u32_bytes(cn), locations(ends), sb, ob, cb])

def encode(result: E.AlignResult) -> List<U32>:
  match result:
    case E.AlignResult{s, d, ends, start, ops, c}:
      encode_parts(status_value(s), distance_value(d), ends,
        (starts(start), (operations(ops), cigar(c))))
