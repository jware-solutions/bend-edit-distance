# bend-edlib

Python tests compare three native executables on identical ordered input pairs:
two-row DP from `DistanceDP.bend`, Myers from `main.bend`, and a small oracle
against the vendored C++ Edlib. Each pytest session compiles each executable
once, then invokes it with literal CLI arguments using `subprocess`. The Python
alignment helpers transport inputs and validate outputs. Direct Myers block
tests also use scalar Python DP columns as an independent internal-state oracle.

## Run tests

From PowerShell at the project root:

```powershell
python run_tests.py --setup  # First run: create a WSL venv and install test dependencies
python run_tests.py -v
```

Windows invocations automatically forward to the default WSL distribution.
Inside WSL, use `python3 run_tests.py` with the same options. Bend, Clang 14+
and a C++14 compiler must be available in that distribution, along with Python
3.10+ and its `venv` module. For Debian/Ubuntu, install the build prerequisites
with `sudo apt-get install clang g++ python3-venv`. `--setup` installs only
Python test dependencies into `build/test-venv`; it does not install system tools.
Run `--setup` again when `requirements-test.txt` changes.

The compiler is pinned to the verified **Bend 2.0.36** in `.bend-version`, and
pytest and Hypothesis are pinned in `requirements-test.txt`. When upgrading Bend, check the
argument convention and native compilation before updating the pin. If Edlib's
submodule is missing, run `git submodule update --init vendor/edlib`.

Every run rebuilds the native binaries to include edits to both Bend entry
points and their imports. The fixtures compile each executable only once per session. Build
failures, process failures, invalid output and timeouts fail tests with command
diagnostics. Build products and the Python environment stay under ignored
`build/`; no existing Edlib CMake build is needed.

## Alignment protocol

`main.bend` returns the global Levenshtein edit distance:

```text
build/bend-edlib --threads 1 -- ACGT ACG
1
```

The default suite compares all three algorithms on known distances, normal and
empty arguments, whitespace, literal shell characters, arguments resembling runtime flags, two CPU threads,
invalid argument counts, Unicode and length-limit rejections, the C++ oracle, subprocess error handling and
`bend PROOF.bend`. `--alignment` adds the extended differential suite.

`IO.args()` includes the program name in this compiler version. Keep the
`Con{_, Con{query, Con{target, Nil{}}}}` pattern in `run`. The Python adapter places
`--` before the sequences so strings such as `--threads` reach your program
unchanged. Exactly two sequences are required; other argument counts exit 2.

Both native Bend executables validate each sequence before computing a distance:

- Characters must be **non-NUL ASCII (U+0001 through U+007F)**. Whitespace,
  control characters, DEL and strings resembling runtime flags are allowed.
  Non-ASCII characters are rejected even when both strings are identical or
  the other string is empty. UTF-8 text is not interpreted as byte input.
- Each sequence may contain **0 through 4,096 characters**, inclusive. This is
  an application limit per argument, not a limit on the sum of their lengths
  or on the edit distance. On supported inputs ASCII characters are one byte.
- Unsupported characters or excessive lengths exit **2**, write a diagnostic
  to **stderr**, and leave **stdout empty**. Invalid argument counts use the
  same error protocol. For example, `build/bend-edlib -- Ā Ā` reports an ASCII
  error instead of a distance.

The 4,096-character cap bounds query-profile allocation and alignment work:
Myers advances at most `4096 * 128` blocks, and the DP test executable computes
at most `4096 * 4096` cells. It also keeps scores well inside `U32` and arguments
below the tested WSL/Linux transport limits. This is a conservative supported
size, not a universal latency guarantee. `Cli.bend` validates both inputs in
parallel with bounded scans (at most 4,097 characters per sequence), before
either algorithm or its empty-input shortcuts run. The Python test adapters
also check lengths before launching a process. The pure distance functions
do not perform this CLI validation; callers must respect the supported domain.

## Implementation

The Myers implementation in `main.bend` ports the distance path from the
vendored `edlib.cpp`:
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

`DistanceDP.bend` independently exports `distance(query, target) -> Nat` and
imports only `Base`. It implements the two-row Levenshtein recurrence:

```text
D[0,j] = j; D[i,0] = i
D[i,j] = min(D[i-1,j] + 1, D[i,j-1] + 1,
             D[i-1,j-1] + (row[i-1] != column[j-1]))
```

The shorter sequence supplies the columns, so both rows have
`min(m, n) + 1` cells. Each row consumes its predecessor; no distance matrix
or traceback is retained. This takes `O(m*n)` time and `O(min(m,n))` score
storage. Scores use `U32`, as in Myers. Input lengths are computed in parallel;
cells and rows remain sequential because each depends on its predecessor.
The existing CLI continues to use Myers. Tests compile `tests/distance_dp.bend`
as `build/bend-distance-dp`, which calls DP directly with the same CLI contract.

`LAWS.bend` states quantified empty-input laws for both implementations,
Myers wildcard padding, case-sensitive masks, high-bit masks, concrete block
transitions and cell decoding, DP's recurrence and initial row width, and concrete
row, distance and CLI-validation examples; `PROOF.bend` proves them. The CLI
laws also record the length cap, empty inputs and exhausted scan capacity.
These laws cover those
properties; three-way differential tests check the broader distance behavior.

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
- **Input transport and size:** command-line arguments cannot carry embedded
  NUL bytes, do not provide a protocol for all 256 byte values, and are subject
  to operating-system argument-length limits. The native Bend CLI explicitly
  rejects non-ASCII characters and sequences longer than 4,096 characters.
  Each pair starts a new process; there is no persistent worker with explicit
  byte lengths or support for larger inputs.
- **Correctness coverage:** independent DP cross-checks Myers and C++ Edlib,
  including the exhaustive small-input matrix, shrinking properties, direct
  masks/block checks and upstream NW regressions described below. This is
  finite test coverage; continuous fuzzing and general correctness proofs
  remain future work. Extended alignment tests require `--alignment`;
  known-distance, case, motif, unequal-length and upstream regressions run by default.
- **Proof coverage:** the laws cover empty inputs, wildcard padding, DP's cell
  recurrence and initial row width, concrete mask/block, row and distance examples, and
  bounded CLI-validation cases.
  They do not prove general identity, carry correctness, equivalence
  with dynamic programming, or optimality for arbitrary inputs. The proof test
  uses the regular checker, and kernel verification with `--verdict` was
  unconfirmed in the reviewed setup because Lean 4.34.0 was missing.
- **Performance and batching:** the reproducible comparison reports native CLI
  latency, including startup; alignment-only benchmarks and measured algorithm
  speedups over C++ Edlib remain absent. Myers evaluates every block without threshold bands,
  early rejection or adaptive retries. Parallelism currently covers
  preprocessing for one pair; there is no CPU batch API, GPU entry point or
  genuine-device test. Tests with multiple CPU threads check correctness only.
- **Library and release readiness:** Myers still lives in `main.bend` alongside
  the CLI; `DistanceDP.bend` exports a reusable DP function. A stable library API
  covering both algorithms, release/version metadata,
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

All three algorithms receive the same ordered pair in every differential comparison.
The suite checks known examples, empty inputs, insertions/deletions/substitutions,
32-bit and 64-bit block boundaries through 257 characters, every final-word
padding size, large distances, 100 reproducible random DNA pairs, ASCII pairs up
to 1,024 characters, and one, two and four Bend CPU threads. The completed
correctness matrix also includes:

- All **14,641 ordered pairs** of the 121 strings over `{A,C,G}` of lengths
  zero through four, compared across all three native implementations.
- Every single-word length **1-32**, with identity, disjoint and empty inputs,
  substitutions/deletions/insertions at every position, and both input orders.
- Hypothesis differential comparisons and identity, symmetry, length bounds
  and triangle inequality for each implementation. These metric properties
  apply only to **unrestricted NW with unit costs and ordinary equality**.
  They must not be applied to prefix/infix distances, threshold sentinels or
  arbitrary custom equalities. Strategies include DNA, mixed case, non-NUL
  ASCII, motifs and lengths around word boundaries through 257.
- A test-only native Bend probe importing production functions. Mask tests
  check each real bit, wildcard padding and every byte-indexed table entry.
  Transition tests compare positive/negative masks, bottom scores, all carry
  signs, complete `advance_column` results and every decoded cell against
  independent scalar DP columns, across single and multiple words.
- Explicit case-sensitive, repetitive-motif and highly imbalanced regressions
  up to the 4,096-character cap, and 17 cases migrated from pinned upstream
  Edlib tests. Migration preserves declared C++ array lengths and zero-filled
  tails via an injective ASCII relabeling; unsupported modes/results are excluded.

Hypothesis uses 100 examples per property (40 for block traces), with replay,
generation and shrinking enabled, no timing deadline, and persistent reduced
failures in ignored `build/hypothesis/`. Re-run the same command to replay them.
Checked-in examples in `tests/regressions/nw.json` run both as explicit
distance regressions and Hypothesis `@example`s, even on a clean checkout.
See [the regression corpus notes](tests/regressions/README.md) for provenance
and how to preserve a newly discovered counterexample. The exhaustive matrix
starts three native processes per pair, so the extended suite can take several minutes.

The distance contract is **NW/global Levenshtein distance**, unit costs,
unlimited threshold (`k = -1`), and one nonnegative decimal integer on stdout.
Inputs are non-NUL ASCII strings of at most 4,096 characters each, so Edlib's
byte semantics match Bend's characters. Direct native CLI tests cover Unicode
rejection in either argument (including empty counterparts), every non-NUL
ASCII character, and accepted/rejected length boundaries on one and two threads.
The CLI bridge cannot transport NUL bytes and has operating-system argument
length limits; the persistent binary worker from the proposal remains a later
extension. Prefix/infix modes, thresholds and alignment paths need new protocol
fields and matching tests before they are supported.

Add cases to `tests/test_alignment.py`, or create your own tests using the
session fixtures and adapters:

```python
import pytest
from tests.helpers import bend_align, bend_dp_align, cpp_edlib_align

@pytest.mark.alignment
def test_my_case(bend_binary, dp_binary, cpp_binary):
    query, target = "ACGT", "AGT"
    expected = cpp_edlib_align(query, target, binary=cpp_binary)
    assert bend_align(query, target, binary=bend_binary) == expected
    assert bend_dp_align(query, target, binary=dp_binary) == expected
```

Normal pytest selectors work through the runner, for example
`python run_tests.py --alignment -k word_boundaries -v` or
`python run_tests.py --alignment -x`. To use pytest directly inside WSL after
setup, run `build/test-venv/bin/python -m pytest tests/ -v` (add `--alignment`
for distances). Run `bend PROOF.bend` in WSL before committing, as required by
`AGENTS.md`.

After running the tests to rebuild the binaries, compare distances and timings
on a fixed corpus from PowerShell at the project root:

```powershell
wsl --exec python3 -m tests.compare --repeats 5 --threads 1
```

Inside WSL, use `python3 -m tests.compare` with the same options. The report is
CSV with one shared distance and median milliseconds for DP, Myers and C++
Edlib. It validates every result, uses seed `20261008`, warms each binary once
per pair, and rotates invocation order. These are **native CLI wall times**,
including process and runtime startup; they do not isolate alignment time.
The empty-input case makes the startup contribution visible. Timing differences
are observations, not test pass/fail thresholds.

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
