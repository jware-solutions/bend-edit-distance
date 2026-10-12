import Base
import ./EdlibTypes.bend as Types
import ./src/Myers.bend as Myers
import ./src/Batch.bend as Batch

# Public CPU library entry point, independent of CLI and foreign transport.
def distance(query: String, target: String) -> Nat:
  Myers.distance(query, target)

def default_config() -> Types.AlignConfig:
  Types.default_config()

def align(query: String, target: String, config: Types.AlignConfig) -> Types.AlignResult:
  Myers.edlib_align(query, target, config)

# One result per job, in input order, with independent CPU alignment leaves.
def align_batch(jobs: List<&2, Types.AlignJob>) -> List<&2, Types.AlignResult>:
  Batch.align_batch(jobs)

# Format any path, including an explicitly empty path, independently of align.
def alignment_to_cigar(operations: List<&2, Types.Operation>, format: Types.CigarFormat) -> String:
  Types.alignment_to_cigar(operations, format)
