import Base

# Benchmark-only foreign effects. mark returns an already evaluated value so
# construction cannot be skipped, delayed into the next phase, or timed by
# subtracting independent process runs. Labels are small U32 phase identifiers.
def start() -> IO(Unit):
  import "./timer.c"

def mark(-A: Type, phase: U32, value: A) -> IO(A):
  import "./timer.c"

def release(-A: Type, value: A) -> IO(Unit):
  import "./timer.c"

def finish(checksum: Nat) -> IO(Unit):
  import "./timer.c"
