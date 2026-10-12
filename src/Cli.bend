import Base
import ../EdlibTypes.bend as E

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

def respond_distance(~distance: String -> String -> Nat, query: String, target: String,
                     status: InputStatus) -> IO(Unit):
  match status:
    case Supported{}:
      IO.print(Nat.show(distance(query, target)))
    case NonAscii{}:
      IO.die(Unit, 2, "Sequences must contain only non-NUL ASCII characters (U+0001..U+007F)")
    case TooLong{}:
      IO.die(Unit, 2, "Sequence length exceeds maximum of " ++
        Nat.show(max_sequence_length()) ++ " ASCII characters per sequence")

def run_distance(~distance: String -> String -> Nat, args: List<String>) -> IO(Unit):
  match args:
    # IO.args includes argv[0]; the native runtime consumes flags before --.
    case Con{_, Con{+query, Con{+target, Nil{}}}}:
      respond_distance(~distance, query, target, validate(query, target))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET")

def read_mode(value: String) -> Maybe<&2, E.Mode>:
  match value:
    case "NW":
      Some{E.NW{}}
    case "SHW":
      Some{E.SHW{}}
    case "HW":
      Some{E.HW{}}
    case _:
      None{}

def read_task(value: String) -> Maybe<&2, E.Task>:
  match value:
    case "DISTANCE":
      Some{E.Distance{}}
    case "LOC":
      Some{E.Locations{}}
    case "PATH":
      Some{E.Path{}}
    case _:
      None{}

def read_format(value: String) -> Maybe<&2, E.CigarFormat>:
  match value:
    case "STANDARD":
      Some{E.Standard{}}
    case "EXTENDED":
      Some{E.Extended{}}
    case _:
      None{}

def bounded_threshold(value: Nat, valid: Bool) -> Maybe<&2, E.Threshold>:
  match valid:
    case True{}:
      Some{E.MaxDistance{value}}
    case False{}:
      None{}

def negative_threshold(magnitude: Nat, valid: Bool) -> Maybe<&2, E.Threshold>:
  match magnitude valid:
    case _ False{}:
      None{}
    case 0n True{}:
      Some{E.MaxDistance{0n}}
    case _ True{}:
      Some{E.Unlimited{}}

def read_threshold(value: String) -> Maybe<&2, E.Threshold>:
  match value:
    case SCon{'-', digits}:
      do Maybe<&2, E.Threshold>:
        +magnitude : Nat <- Nat.read(digits)
        negative_threshold(magnitude, Nat.is_le(magnitude, 2147483648n))
    case _:
      do Maybe<&2, E.Threshold>:
        +maximum : Nat <- Nat.read(value)
        bounded_threshold(maximum, Nat.is_le(maximum, 2147483647n))

def read_pairs(value: String) -> Maybe<&2, List<&2, E.EqualityPair>>:
  match value:
    case SNil{}:
      Some{Nil{}}
    case SCon{_, SNil{}}:
      None{}
    case SCon{first, SCon{second, tail}}:
      do Maybe<&2, List<&2, E.EqualityPair>>:
        pairs : List<&2, E.EqualityPair> <- read_pairs(tail)
        return E.EqualityPair{first, second} <> pairs

def parse(mode: String, task: String, threshold: String, pairs: String,
          format: String) -> Maybe<&2, E.AlignConfig>:
  do Maybe<&2, E.AlignConfig>:
    m : E.Mode <- read_mode(mode)
    t : E.Task <- read_task(task)
    k : E.Threshold <- read_threshold(threshold)
    eq : List<&2, E.EqualityPair> <- read_pairs(pairs)
    c : E.CigarFormat <- read_format(format)
    return E.AlignConfig{m, t, k, eq, c}

def respond_alignment(~align: String -> String -> E.AlignConfig -> E.AlignResult,
                      query: String, target: String, config: Maybe<&2, E.AlignConfig>,
                      status: InputStatus) -> IO(Unit):
  match config status:
    case None{} _:
      IO.die(Unit, 2, "Invalid alignment configuration")
    case Some{value} Supported{}:
      IO.print(E.result_show(align(query, target, value)))
    case _ NonAscii{}:
      IO.die(Unit, 2, "Sequences and equality pairs must contain only non-NUL ASCII characters")
    case _ TooLong{}:
      IO.die(Unit, 2, "Sequence or equality-pair length exceeds maximum of 4096 ASCII characters")

def run_alignment(~align: String -> String -> E.AlignConfig -> E.AlignResult,
                  args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--config" <> mode <> task <> threshold <> +pairs <> format <> +query <> +target <> Nil{}:
      respond_alignment(~align, query, target, parse(mode, task, threshold, pairs, format),
        combine(validate(query, target), scan(pairs, max_sequence_length())))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET or --config MODE TASK K PAIRS CIGAR QUERY TARGET")

# Retain the legacy distance response for exactly two sequence arguments.
def run(~distance: String -> String -> Nat,
        ~align: String -> String -> E.AlignConfig -> E.AlignResult,
        args: List<String>) -> IO(Unit):
  match args:
    case _ <> query <> target <> Nil{}:
      run_distance(~distance, ["bend-edit-distance", query, target])
    case _:
      run_alignment(~align, args)
