import Base
import ../DistanceDP.bend as DP

# Separate executable so differential tests exercise DP without Myers dispatch.
def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{query, Con{target, Nil{}}}}:
      IO.print(Nat.show(DP.distance(query, target)))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
