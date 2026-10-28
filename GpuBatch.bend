import Base
import ./src/Batch.bend as B
import ./EdlibTypes.bend as E

# Keep host planning and ordered-result restoration outside the single bang.
# The same independent alignment leaves and carry dependencies serve both chips.
def execute(plan: B.Plan) -> List<&2, B.IndexedResult>:
  B.execute!(plan)

def ordered(values: List<&2, B.IndexedResult>) -> List<&2, E.AlignResult>:
  B.ordered(values)

def align_plan(plan: B.Plan) -> List<&2, E.AlignResult>:
  match plan:
    case B.Ordered{inner}:
      B.results(execute(inner))
    case _:
      ordered(execute(plan))

# Explicit opt-in module: CPU consumers of lib.bend need no GPU toolchain.
def align_batch(jobs: List<&2, E.AlignJob>) -> List<&2, E.AlignResult>:
  align_plan(B.prepare(jobs))
