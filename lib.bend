import Base
import ./EdlibTypes.bend as Types
import ./main.bend as Main
import ./Batch.bend as Batch

# Public BendHub library entry point. Keep CLI startup behind main.bend's main.
def distance(query: String, target: String) -> Nat:
  Main.distance(query, target)

def default_config() -> Types.AlignConfig:
  Types.default_config()

def align(query: String, target: String, config: Types.AlignConfig) -> Types.AlignResult:
  Main.edlib_align(query, target, config)

# One result per job, in input order, with independent CPU alignment leaves.
def align_batch(jobs: List<&2, Types.AlignJob>) -> List<&2, Types.AlignResult>:
  Batch.align_batch(jobs)

# Format any path, including an explicitly empty path, independently of align.
def alignment_to_cigar(operations: List<&2, Types.Operation>, format: Types.CigarFormat) -> String:
  Types.alignment_to_cigar(operations, format)
