import Base
import ./Cli.bend as CLI
import ./EdlibTypes.bend as E

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

def respond(~align: String -> String -> E.AlignConfig -> E.AlignResult,
            query: String, target: String, config: Maybe<&2, E.AlignConfig>,
            status: CLI.InputStatus) -> IO(Unit):
  match config status:
    case None{} _:
      IO.die(Unit, 2, "Invalid alignment configuration")
    case Some{value} CLI.Supported{}:
      IO.print(E.result_show(align(query, target, value)))
    case _ CLI.NonAscii{}:
      IO.die(Unit, 2, "Sequences and equality pairs must contain only non-NUL ASCII characters")
    case _ CLI.TooLong{}:
      IO.die(Unit, 2, "Sequence or equality-pair length exceeds maximum of 4096 ASCII characters")

def run(~align: String -> String -> E.AlignConfig -> E.AlignResult,
        args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--config" <> mode <> task <> threshold <> +pairs <> format <> +query <> +target <> Nil{}:
      respond(~align, query, target, parse(mode, task, threshold, pairs, format),
        CLI.combine(CLI.validate(query, target), CLI.scan(pairs, CLI.max_sequence_length())))
    case _:
      IO.die(Unit, 2, "Expected QUERY TARGET or --config MODE TASK K PAIRS CIGAR QUERY TARGET")
