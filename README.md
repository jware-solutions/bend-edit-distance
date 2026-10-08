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

## Limitations

The supported contract is ASCII, global (NW) Levenshtein distance with unit edit
costs and no distance limit. The project implements part of Edlib's behavior.
The following features and checks are still missing from this repository:

- **Other alignment features and results:** aligning against a target prefix
  (SHW) or substring (HW),
  a maximum-distance threshold (`k`), custom character equalities, start/end
  locations, alignment paths, and standard or extended CIGAR strings (compact
  descriptions of the edits) are unsupported. The API and C++ test oracle return
  only a nonnegative distance; they do not expose Edlib's full configuration,
  status, task-dependent results, or `-1` values for missing results/positions.
- **Input validation:** the Python distance adapters reject non-ASCII text, but
  the executable itself does not. Unsupported Unicode can silently produce wrong
  distances: aligning `"Ā"` with `"Ā"` returned `1` in the review. Use ASCII only.
- **Input transport and size:** command-line arguments cannot carry embedded
  NUL bytes, do not provide a protocol for all 256 byte values, and are subject
  to operating-system argument-length limits. Practical sequence-length limits
  are not yet documented or enforced. Each pair starts a new process; there is
  no persistent worker with explicit byte lengths.
- **Correctness coverage:** there is no independent, simpler Bend alignment
  algorithm (dynamic programming) for cross-checking Myers. Exhaustive small-input
  testing, property-based testing with reduced counterexamples, fuzzing,
  systematic checks of lengths 1-32 and individual bit-vector steps,
  and some case-sensitivity, repetitive, imbalanced-length and upstream
  regressions remain to be added. Extended alignment tests require
  `--alignment`; they do not run by default.
- **Proof coverage:** the laws cover empty inputs, one padding property and six
  examples. They do not prove general identity, carry correctness, equivalence
  with dynamic programming, or optimality for arbitrary inputs. The proof test
  uses the regular checker, and kernel verification with `--verdict` was
  unconfirmed in the reviewed setup because Lean 4.34.0 was missing.
- **Performance and batching:** there are no reproducible benchmarks or measured
  speedups over C++ Edlib. Myers evaluates every block without threshold bands,
  early rejection or adaptive retries. Parallelism currently covers
  preprocessing for one pair; there is no CPU batch API, GPU entry point or
  genuine-device test. Tests with multiple CPU threads check correctness only.
- **Library and release readiness:** the algorithm still lives in `main.bend`
  alongside the CLI. A stable reusable library API, release/version metadata,
  compatibility matrix, project CI and automated clean-checkout tool setup are
  still missing; the test runner relies on separately installed system tools.

There are also constraints in the pinned **Bend 2.0.36** and current WSL setup:

1. **GPU execution falls back to the CPU under stock Bend on WSL2.** The runtime
   requires concurrent managed-memory access that WSL2 GPUs do not provide.
   Installing CUDA alone does not fix this. GPU validation and benchmarks need
   a supported environment or changes to Bend's runtime. See the
   [WSL2 CUDA issue](https://github.com/bendlang/bend/issues/1066).
2. **Bend cannot directly build a replacement for Edlib's native C library.**
   Its normal native output is a complete program with `main`, without a
   supported way to export selected functions, a C header and runtime
   setup/teardown. A reusable Bend module and CLI are possible; Edlib's C
   calling interface needs additional compiler/runtime bridge work. See the
   [native library target issue](https://github.com/bendlang/bend/issues/813).
3. **Native 64-bit Myers words are unavailable.** Bend has no native `U64`, so
   this implementation uses 32-bit blocks instead of Edlib's 64-bit blocks.
   Longer inputs use multiple blocks; this does not limit sequences to 32
   characters or prevent implementing the remaining Edlib features. Emulating
   64-bit operations would require extra code. See
   [Bend's version-pinned limits](https://github.com/bendlang/bend/blob/v2.0.36/WONTFIX.txt).
4. **Native Windows execution is unsupported.** Run Bend and the compiled
   executable inside WSL on Windows. A native Windows binary is not a supported
   release target. See
   [Bend's platform limits](https://github.com/bendlang/bend/blob/v2.0.36/WONTFIX.txt#L71-L80).
5. **Parallel work must be balanced and respect memory ownership.** Bend's
   scheduler splits and joins work without redistributing tasks between cores.
   Ordinary arrays have one owner; experimental arrays shared through atomic
   operations require `@unsafe`. Independent alignments can run in parallel,
   but arbitrary recursion or a shared mutable alignment matrix will not
   automatically scale safely. See the
   [parallelism and array guide](https://github.com/bendlang/bend/blob/v2.0.36/guide/GUIDE.md#parallelism)
   and [atomic-array limitation](https://github.com/bendlang/bend/blob/v2.0.36/README.md#limitations).
6. **Proofs do not certify the whole compiled executable.** `--verdict` checks
   translated terms through a proof kernel; the parser, translation and
   native/GPU backends are outside that guarantee. Stronger alignment proofs
   are possible, but runtime comparisons against Edlib are still needed. See
   [Bend's verification limits](https://github.com/bendlang/bend/blob/v2.0.36/README.md#limitations)
   and the [native-library verification scope](https://github.com/bendlang/bend/issues/813).

Byte input (including NUL and all 256 values), explicit missing-result values,
additional alignment modes, thresholds, equalities, locations, paths and CIGAR
can be implemented with further work. Their current absence is a project gap.

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

## License

bend-edlib is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
You may use, modify and redistribute it under the terms in [LICENSE](LICENSE).
Redistributed modified versions must remain under GPL-3.0, and distributed
binaries must be accompanied by access to the corresponding source as the
license requires. The software comes without warranty, to the extent permitted
by applicable law.

The vendored C++ Edlib dependency retains its
[MIT license](vendor/edlib/LICENSE) and copyright notice.
