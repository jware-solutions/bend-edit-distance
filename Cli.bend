import Base

# Shared boundary for native distance executables. Keep validation ahead of
# distance evaluation, including empty-input shortcuts in either algorithm.
type InputStatus is Data:
  Supported{}
  NonAscii{}
  TooLong{}

def max_sequence_length() -> Nat:
  4096n

def scan_ascii(rest: Unit -> InputStatus, ascii: Bool) -> InputStatus:
  match ascii:
    case True{}:
      rest(Unit{})
    case False{}:
      NonAscii{}

# Inspect at most limit + 1 characters, without an unbounded length pass.
# Match the empty string first so a sequence exactly at the limit is valid.
def scan(sequence: String, remaining: Nat) -> InputStatus:
  match sequence remaining:
    case SNil{} _:
      Supported{}
    case SCon{h, t} 0n:
      TooLong{}
    case SCon{h, t} 1n+p:
      +code = Char.to_u32(h)
      scan_ascii(_ => scan(t, p),
        Bool.and(U32.is_gt(code, 0), U32.is_le(code, 127)))

def combine(query: InputStatus, target: InputStatus) -> InputStatus:
  match query:
    case Supported{}:
      target
    case NonAscii{}:
      NonAscii{}
    case TooLong{}:
      TooLong{}

def validate(query: String, target: String) -> InputStatus:
  q t = scan(query, max_sequence_length()) scan(target, max_sequence_length())
  combine(q, t)

def respond(~distance: String -> String -> Nat, query: String, target: String,
            status: InputStatus) -> IO(Unit):
  match status:
    case Supported{}:
      IO.print(Nat.show(distance(query, target)))
    case NonAscii{}:
      IO.die(Unit, 2, "Sequences must contain only non-NUL ASCII characters (U+0001..U+007F)")
    case TooLong{}:
      IO.die(Unit, 2, "Sequence length exceeds maximum of " ++
        Nat.show(max_sequence_length()) ++ " ASCII characters per sequence")

def run(~distance: String -> String -> Nat, args: List<String>) -> IO(Unit):
  match args:
    # IO.args includes argv[0]; the native runtime consumes flags before --.
    case Con{_, Con{+query, Con{+target, Nil{}}}}:
      respond(~distance, query, target, validate(query, target))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET")
