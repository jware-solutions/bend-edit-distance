import Base

# Benchmark boundaries force their values before reading the monotonic clock.
def ready() -> IO(Unit):
  import "./gate_metrics.c"

def reset() -> IO(Unit):
  import "./gate_metrics.c"

def mark(-A: Type, phase: U32, value: A) -> IO(A):
  import "./gate_metrics.c"

def finish() -> IO(Unit):
  import "./gate_metrics.c"
