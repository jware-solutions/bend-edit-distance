import Base

# Validation-only effects compiled against the pinned, instrumented runtime.
# Passing the value through an effect forces each stage before its timer ends.
def begin(-A: Type, prefetch: Bool, value: A) -> IO(A):
  import "./gpu_metrics.c"

def end(-A: Type, value: A) -> IO(A):
  import "./gpu_metrics.c"

def finish() -> IO(Unit):
  import "./gpu_metrics.c"
