import Base
import ./main.bend as Main

# The starter protocol reports both lengths, including empty strings.
# Replace these smoke laws with alignment laws when response returns distance.
law smoke_empty:
  {Main.response("", "") == "0,0" : String}

law smoke_example:
  {Main.response("ACGT", "ACG") == "4,3" : String}

# CLI contract (checked by Python integration tests):
# - Exactly two positional sequence arguments after the program name.
# - Successful stdout contains only the response and a trailing newline.
# - Invalid argument counts exit with status 2.
# - In alignment mode: ASCII sequences, NW/global mode, unit edit costs,
#   unlimited distance (k = -1), one nonnegative decimal integer on stdout.
# - CLI arguments cannot contain NUL; use a future binary worker for that.
