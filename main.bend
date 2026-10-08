import Base

# Temporary Python/native smoke protocol. Replace this body with
# Nat.show(edlib_align(query, target)) when implementing global edit distance.
def response(query: String, target: String) -> String:
  query_length target_length = String.length(query) String.length(target)
  Nat.show(query_length) ++ "," ++ Nat.show(target_length)

def run(args: List<String>) -> IO(Unit):
  match args:
    # IO.args includes argv[0]; the native runtime consumes flags before --.
    case Con{_, Con{query, Con{target, Nil{}}}}:
      IO.print(response(query, target))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
