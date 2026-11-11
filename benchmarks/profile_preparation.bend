import Base
import ../EdlibTypes.bend as E
import ../src/Profile.bend as P
import ../src/Sequence.bend as S
import ../src/Transport.bend as BT
import ./gate_metrics.bend as T
import ./gate_input.bend as Input

# Isolated production byte-profile construction. Length is cached before the
# first timer; this boundary excludes validation, workspace and pool creation.
def rounds(fuel: Nat, +query: String, +length: Nat, +pairs: List<&2, E.EqualityPair>) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        ignored : List<&2, String> <- Input.read_targets(0n)
        T.reset()
        profile : P.Profile <- T.mark(P.Profile, 3, P.build(query, length, pairs))
        owned : P.Profile <- T.owners(P.Profile, profile, 1)
        T.dispose(P.Profile, 4, owned)
        T.mark(Unit, 6, Unit{})
        T.finish()
        rounds(p, query, length, pairs)

def cached(repeat: Nat, +query: String, +pairs: List<&2, E.EqualityPair>, length: Nat) -> IO(Unit):
  do IO<Unit>:
    T.reset()
    T.finish()
    rounds(repeat, query, length, pairs)

def setup(repeat: Nat, jobs: List<&2, E.AlignJob>) -> IO(Unit):
  match jobs:
    case E.AlignJob{+query, _, E.AlignConfig{_, _, _, pairs, _}} <> Nil{}:
      cached(repeat, query, pairs, S.length(query))
    case _:
      IO.die(Unit, 2, "Expected one query setup")

def parsed(repeat: Maybe<&2, Nat>) -> IO(Unit):
  match repeat:
    case Some{count}:
      do IO<Unit>:
        jobs : List<&2, E.AlignJob> <- BT.read_batch(1n)
        setup(count, jobs)
    case None{}:
      IO.die(Unit, 2, "Expected PROFILE-ONLY 0 ROUNDS SHARDS")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "profile-only" <> "0" <> repeat <> shards <> Nil{}:
      parsed(Nat.read(repeat))
    case _:
      IO.die(Unit, 2, "Expected PROFILE-ONLY 0 ROUNDS SHARDS")

def main() -> IO(Unit):
  do IO<Unit>:
    T.ready()
    args : List<String> <- IO.args()
    run(args)
