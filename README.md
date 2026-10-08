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

## Starter protocol

`main.bend` currently returns the two sequence lengths, as in the proposal:

```text
build/bend-edlib --threads 1 -- ACGT ACG
4,3
```

The two independent length computations use Bend's parallel binding. The default
suite checks normal and empty arguments, whitespace, literal shell characters,
arguments resembling runtime flags, two CPU threads, invalid argument counts,
the C++ oracle, subprocess error handling and `bend PROOF.bend`. Alignment tests
are explicitly skipped until enabled; a passing smoke suite validates the bridge,
not alignment correctness.

`IO.args()` includes the program name in this compiler version. Keep the
`Con{_, Con{query, Con{target, Nil{}}}}` pattern in `run`. The Python adapter places
`--` before the sequences so strings such as `--threads` reach your program
unchanged. Exactly two sequences are required; other argument counts exit 2.

## Implement and test alignment

1. Implement your distance function in `main.bend` and change `response` to return
   its decimal distance, for example `Nat.show(edlib_align(query, target))` for
   a function returning `Nat`. Keep the CLI adapter and print only that result
   on stdout; send diagnostics to stderr.
2. Replace the starter smoke laws in `LAWS.bend` with the intended alignment
   properties and update `PROOF.bend` to prove them.
3. Run the distance suite:

```powershell
python run_tests.py --alignment -v
```

`--alignment` replaces the temporary length tests with differential tests against
C++ Edlib. It tests known examples, empty inputs, insertions/deletions/substitutions,
63/64/65 and 127/128/129 length boundaries, 100 reproducible random DNA pairs, and
multiple CPU threads. It deliberately fails against the starter length response.
Use it from the start of algorithm development for a red/green TDD cycle.

The initial distance contract is **NW/global Levenshtein distance**, unit costs,
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
