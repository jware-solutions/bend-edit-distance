import Base
import ../EdlibTypes.bend as E
import ../Prepared.bend as Q
import ./PreparedPool.bend as P
import ./PreparedByteTransport.bend as Bytes
import ./PreparedBytePool.bend as BytePool
import ./Transport.bend as BT

def prepare_one(query: String, pairs: List<&2, E.EqualityPair>) -> P.Pool:
  P.prepare_with_max(1n, query, pairs)

def prepare_two(query: String, pairs: List<&2, E.EqualityPair>) -> P.Pool:
  P.prepare_with_max(2n, query, pairs)

def prepare_four(query: String, pairs: List<&2, E.EqualityPair>) -> P.Pool:
  P.prepare_with_max(4n, query, pairs)

# The binary codec guarantees byte inputs. Planning finishes before forks.
def batch(pool: P.Pool, targets: List<&2, String>, options: Q.Options) -> P.Pool & List<&2, E.AlignResult>:
  +shared = options
  P.align_ready_known(P.ready(pool, targets, shared), shared, True{})

def targets(values: List<&2, BT.SizedTarget>, +index: Nat, +length: Nat,
               +options: Q.Options) -> List<&2, P.Target>:
  match values:
    case Nil{}:
      Nil{}
    case BT.SizedTarget{sequence, columns} <> tail:
      P.target.sized(index, sequence, columns, length, options) <> targets(tail, 1n+index, length, options)

def ready(pool: P.Pool, values: List<&2, BT.SizedTarget>, options: Q.Options) -> P.PoolReady:
  P.Pool{owners, shards, +length, budget} = pool
  P.ready.inspected(P.Pool{owners, shards, length, budget}, targets(values, 0n, length, options))

def batch_sized(pool: P.Pool, targets: List<&2, BT.SizedTarget>, options: Q.Options) -> P.Pool & List<&2, E.AlignResult>:
  +shared = options
  P.align_ready_known(ready(pool, targets, shared), shared, True{})

def single(pool: P.Pool, target: BT.SizedTarget, options: Q.Options) -> P.Pool & E.AlignResult:
  P.single_result(batch_sized(pool, [target], options))

def serve_with(~prepare: String -> List<&2, E.EqualityPair> -> P.Pool) -> IO(Unit):
  Bytes.serve_generic(~P.Pool, ~prepare, ~P.retained, ~single, ~batch_sized, ~BytePool.single, ~BytePool.many)

def serve(shards: String) -> IO(Unit):
  match shards:
    case "1":
      serve_with(~prepare_one)
    case "2":
      serve_with(~prepare_two)
    case "4":
      serve_with(~prepare_four)
    case _:
      IO.die(Unit, 2, "Expected 1, 2 or 4 prepared-query shards")
