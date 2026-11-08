import Base
import ../src/PreparedTransport.bend as P

# Shipped compatibility implementation, deliberately rejecting optional 6/7/8.
# This is an untimed continuation diagnostic, never an owned performance sample.
def main() -> IO(Unit):
  P.serve()
