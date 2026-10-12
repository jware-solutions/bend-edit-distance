import Base
import ../lib.bend as Edlib
import ../EdlibTypes.bend as E

# Compile in WSL, then run with --threads 1, 2 or 4. Result order is input order.
def main() -> IO(Unit):
  results = Edlib.align_batch([
    E.AlignJob{"kitten", "sitting", Edlib.default_config()},
    E.AlignJob{"AC", "TACGAC", E.AlignConfig{E.HW{}, E.Path{},
      E.Unlimited{}, Nil{}, E.Extended{}}},
    E.AlignJob{"", "ACGT", Edlib.default_config()}])
  IO.print(List.show(~&2, ~E.AlignResult, ~E.result_show, results))
