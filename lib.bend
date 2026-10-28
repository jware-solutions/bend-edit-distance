import ./Prepared.bend as Q
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

# Prepared masks and mutable search state have one owner. Concurrent callers
# use clone_prepared or independent prepare calls, then retain returned owners.
def prepare(query: String, equalities: List<&2, Types.EqualityPair>) -> Q.Prepared:
  Q.prepare(query, equalities)

def default_prepared_options() -> Q.Options:
  Q.default_options()

def align_prepared(prepared: Q.Prepared, target: String, options: Q.Options) -> Q.Prepared & Types.AlignResult:
  Q.align(prepared, target, options)

def align_prepared_batch(prepared: Q.Prepared, targets: List<&2, String>, options: Q.Options) ->
    Q.Prepared & List<&2, Types.AlignResult>:
  Q.align_batch(prepared, targets, options)

def clone_prepared(prepared: Q.Prepared) -> Q.Prepared & Q.Prepared:
  Q.clone(prepared)
