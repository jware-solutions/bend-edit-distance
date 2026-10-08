# bend-edlib

Python tests call a compiled native executable built from the root `main.bend`.
Each pytest session compiles it once, then invokes it with literal CLI arguments
using `subprocess`. The test framework also compiles a small oracle against the
vendored C++ Edlib. Neither helper implements the Bend alignment algorithm.

## Run tests

From PowerShell at the project root:

```powershell
python run_tests.py --setup  # First run: create a WSL venv and install pytest
python run_tests.py -v
```

Windows invocations automatically forward to the default WSL distribution.
Inside WSL, use `python3 run_tests.py` with the same options. Bend, Clang 14+
and a C++14 compiler must be available in that distribution, along with Python
3.10+ and its `venv` module. For Debian/Ubuntu, install the build prerequisites
with `sudo apt-get install clang g++ python3-venv`. `--setup` installs only
Python test dependencies into `build/test-venv`; it does not install system tools.

The compiler is pinned to the verified **Bend 2.0.36** in `.bend-version`, and
pytest is pinned in `requirements-test.txt`. When upgrading Bend, check the
argument convention and native compilation before updating the pin. If Edlib's
submodule is missing, run `git submodule update --init vendor/edlib`.

Every run rebuilds the native binaries to include edits to `main.bend` and its
imports. The fixtures compile each executable only once per session. Build
failures, process failures, invalid output and timeouts fail tests with command
diagnostics. Build products and the Python environment stay under ignored
`build/`; no existing Edlib CMake build is needed.

## Alignment protocol

`main.bend` returns the global Levenshtein edit distance:

```text
build/bend-edlib --threads 1 -- ACGT ACG
1
```

The default suite checks distances for normal and empty arguments, whitespace,
literal shell characters, arguments resembling runtime flags, two CPU threads,
invalid argument counts, the C++ oracle, subprocess error handling and
`bend PROOF.bend`. `--alignment` adds the extended differential suite.

`IO.args()` includes the program name in this compiler version. Keep the
`Con{_, Con{query, Con{target, Nil{}}}}` pattern in `run`. The Python adapter places
`--` before the sequences so strings such as `--threads` reach your program
unchanged. Exactly two sequences are required; other argument counts exit 2.

## Implementation

The Bend implementation ports the distance path from the vendored `edlib.cpp`:
`build_peq`/`build_peq_word` build equality masks, `calculate_block` advances a
Myers bit-vector block, `get_block_cell_value` removes wildcard padding from the
final score, and `myers_calc_edit_distance_nw` advances the global alignment.
`edlib_align` handles empty inputs and selects the shorter sequence as the query.

Blocks use native `U32` words with 32 query positions, adapting Edlib's 64-bit
words. Immutable byte-indexed query tables are built with balanced parallel
calls; the two input lengths are also computed in parallel. Blocks within a
column and consecutive columns remain sequential because their carries depend
on the preceding calculation. The unlimited-distance implementation evaluates
all blocks directly, without threshold-band retries or traceback storage.
For lengths `m <= n`, it advances `n * ceil(m / 32)` blocks and stores only the
current column and query profiles.

`LAWS.bend` states quantified empty-input and wildcard-padding laws plus concrete
alignment examples; `PROOF.bend` proves them. These laws cover those properties,
while differential tests check the general distance implementation against Edlib.

## Test alignment

Run the extended distance suite from PowerShell:

```powershell
python run_tests.py --alignment -v
```

Or invoke WSL directly:

```powershell
wsl bash -ic 'python3 run_tests.py --alignment -v'
```

The suite checks known examples, empty inputs, insertions/deletions/substitutions,
32-bit and 64-bit block boundaries through 257 characters, every final-word
padding size, large distances, 100 reproducible random DNA pairs, ASCII pairs up
to 1,024 characters, and one, two and four CPU threads.

The distance contract is **NW/global Levenshtein distance**, unit costs,
unlimited threshold (`k = -1`), and one nonnegative decimal integer on stdout.
Inputs are ASCII strings so Edlib's byte semantics match Bend's characters.
The CLI bridge cannot transport NUL bytes and has operating-system argument
length limits; the persistent binary worker from the proposal remains a later
extension. Prefix/infix modes, thresholds and alignment paths need new protocol
fields and matching tests before they are supported.

Add cases to `tests/test_alignment.py`, or create your own tests using the
session fixtures and adapters:

```python
import pytest
from tests.helpers import bend_align, cpp_edlib_align

@pytest.mark.alignment
def test_my_case(bend_binary, cpp_binary):
    query, target = "ACGT", "AGT"
    assert bend_align(query, target, binary=bend_binary) == cpp_edlib_align(
        query, target, binary=cpp_binary,
    )
```

Normal pytest selectors work through the runner, for example
`python run_tests.py --alignment -k word_boundaries -v` or
`python run_tests.py --alignment -x`. To use pytest directly inside WSL after
setup, run `build/test-venv/bin/python -m pytest tests/ -v` (add `--alignment`
for distances). Run `bend PROOF.bend` in WSL before committing, as required by
`AGENTS.md`.

The CLI convention follows the installed `bend guide`; see also the official
[Bend guide](https://github.com/bendlang/bend/blob/main/guide/GUIDE.md) and
[native compilation documentation](https://bend2.dev/learn/compile-to-c/).
