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

def owners(-A: Type, value: A, count: U32) -> IO(A):
  import "./gate_metrics.c"

# Diagnostic plan traversal is forced before this effect. Discard its elapsed
# interval so it cannot be misreported as search or fork/join work.
def leaves(-A: Type, value: A, count: U32) -> IO(A):
  import "./gate_metrics.c"

# Force disposal inside the measured interval, including recursive drops.
def dispose(-A: Type, phase: U32, value: A) -> IO(Unit):
  import "./gate_metrics.c"
