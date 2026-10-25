import Base
import ../GpuBatch.bend as G
import ../EdlibTypes.bend as E

def main() -> IO(Unit):
  results = G.align_batch([
    E.AlignJob{"kitten", "sitting", E.default_config()},
    E.AlignJob{"AC", "TACGAC", E.AlignConfig{E.HW{}, E.Path{},
      E.Unlimited{}, Nil{}, E.Extended{}}},
    E.AlignJob{"", "ACGT", E.default_config()}])
  IO.print(List.show(~&2, ~E.AlignResult, ~E.result_show, results))
