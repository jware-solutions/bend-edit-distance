# bend-edlib

Python tests compare three native executables on identical ordered input pairs:
two-row DP from `DistanceDP.bend`, Myers from `main.bend`, and a small oracle
against the vendored C++ Edlib. Each pytest session compiles each executable
once, then invokes it with literal CLI arguments using `subprocess`. The Python
helpers only transport inputs and validate outputs.

## Run tests

From PowerShell at the project root:

```powershell
python run_tests.py --setup  # Install native tools, pinned Bend/Lean, Edlib and Python dependencies
python run_tests.py -v
```

Windows invocations automatically forward to the default WSL distribution.
Inside WSL, use `python3 run_tests.py` with the same options. Start with an
installed Debian/Ubuntu WSL distribution and Windows Python, or Debian/Ubuntu
Linux with Python 3.10+. Setup invokes `scripts/setup.sh`: it installs native
Clang, g++, Python venv support, Git, curl, certificates and zstd through apt
(using sudo when needed), initializes submodules at their recorded commits,
downloads the exact Bend and Lean releases, builds a fresh BendTT proof kernel,
and creates `build/test-venv` with the pinned Python dependencies. Internet access
and permission to install apt packages are required for full setup.

The compiler is pinned to **Bend 2.0.36** in `.bend-version`, its proof toolchain
to **Lean 4.34.0** in `.lean-version`, and pytest, Hypothesis and their transitive
dependencies in `requirements-test.txt`. Linux x86_64 and aarch64 downloads are
verified against the committed `scripts/tools.sha256` before extraction. When
upgrading Bend, review CLI compatibility, Lean requirements and archive checksums
together. Native compiler packages come from the selected distribution; their
versions and the submodule revision are recorded in `build/environment.txt`.

For a clean Linux checkout (submodules need not already be initialized):

```bash
git clone https://github.com/jware-solutions/bend-edlib.git
cd bend-edlib
bash scripts/setup.sh
python3 run_tests.py --alignment --verdict -v
```

`bash scripts/setup.sh --native-only` omits Lean and the proof kernel for the
fast and benchmark tiers. Add `--skip-system` only when the apt prerequisites
are already installed. Setup replaces its tool installations and clears the
test venv on every invocation. No preexisting Bend, Bun, Lean, elan, Edlib CMake
build, or user proof-kernel cache is needed. The runner gives the project tools
priority over system installations and selects the project kernel explicitly.

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
invalid argument counts, the C++ oracle, subprocess error handling,
32-bit word boundaries, 20 deterministic Hypothesis examples (plus explicit
regressions), release-note generation, and `bend PROOF.bend`. `--alignment`
adds the extended differential/property suite; `--verdict` also checks proofs
with the Lean-backed kernel.

`IO.args()` includes the program name in this compiler version. Keep the
`Con{_, Con{query, Con{target, Nil{}}}}` pattern in `run`. The Python adapter places
`--` before the sequences so strings such as `--threads` reach your program
unchanged. Exactly two sequences are required; other argument counts exit 2.

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
Myers wildcard padding, DP's recurrence and initial row width, and concrete
row and distance examples; `PROOF.bend` proves them. These laws cover those
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
- **Input validation:** the Python distance adapters reject non-ASCII text, but
  the executable itself does not. Unsupported Unicode can silently produce wrong
  distances: aligning `"Ā"` with `"Ā"` returned `1` in the review. Use ASCII only.
- **Input transport and size:** command-line arguments cannot carry embedded
  NUL bytes, do not provide a protocol for all 256 byte values, and are subject
  to operating-system argument-length limits. Practical sequence-length limits
  are not yet documented or enforced. Each pair starts a new process; there is
  no persistent worker with explicit byte lengths.
- **Correctness coverage:** independent DP now cross-checks Myers and C++ Edlib,
  including every pair of binary-alphabet strings up to length three and highly
  unequal lengths in both orders. Hypothesis supplies shrinking counterexamples
  and checks symmetry, identity, empty inputs, distance bounds, common suffixes
  and the triangle inequality. Fuzzing, systematic checks of lengths 1-32 and individual
  bit-vector steps, and broader case-sensitivity, repetitive and upstream
  regressions remain to be added. Extended alignment tests require
  `--alignment`; known-distance, word-boundary, small property and unequal-length
  comparisons run by default. CI explicitly runs both tiers.
- **Proof coverage:** the laws cover empty inputs, wildcard padding, DP's cell
  recurrence and initial row width, and concrete row and distance examples.
  They do not prove general identity, carry correctness, equivalence
  with dynamic programming, or optimality for arbitrary inputs. The proof test
  runs the regular checker by default; extended CI also provisions Lean 4.34.0
  and requests kernel verification with `--verdict`.
- **Performance and batching:** the reproducible comparison reports native CLI
  latency, including startup; alignment-only benchmarks and measured algorithm
  speedups over C++ Edlib remain absent. Myers evaluates every block without threshold bands,
  early rejection or adaptive retries. Parallelism currently covers
  preprocessing for one pair; there is no CPU batch API, GPU entry point or
  genuine-device test. Tests with multiple CPU threads check correctness only.
- **Library and release readiness:** Myers still lives in `main.bend` alongside
  the CLI; `DistanceDP.bend` exports a reusable DP function. A stable library API
  covering both algorithms, semantic library versioning and a broader platform
  compatibility matrix remain to be added. CI, clean-checkout tool setup and
  per-push source releases are automated as described below.

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
python run_tests.py --alignment --verdict -v
```

Or invoke WSL directly:

```powershell
wsl --exec python3 run_tests.py --alignment --verdict -v
```

All three algorithms receive the same ordered pair in every differential comparison.
The suite checks known examples, empty inputs, insertions/deletions/substitutions,
32-bit and 64-bit block boundaries through 257 characters, every final-word
padding size, large distances, 100 reproducible random DNA pairs, ASCII pairs up
to 1,024 characters, every pair of binary-alphabet strings up to length three,
highly unequal lengths in both orders, and one, two and four Bend CPU threads.
The extended Hypothesis test checks 100 deterministic examples with ASCII
strings up to length 96; failures shrink to smaller counterexamples. Its
metamorphic checks cross-compare all three implementations for every derived
pair, including reversed inputs and common suffixes.

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
setup, prefer the runner so the downloaded tools and kernel are selected.
For direct pytest, first export `PATH="$PWD/build/tools/bend/bin:$PATH"`
and `BENDTT="$PWD/build/tools/kernel/bendtt"`, then run
`build/test-venv/bin/python -m pytest tests/ -v` (add `--alignment --verdict`
for the full suite). Run `build/tools/bend/bin/bend PROOF.bend` in WSL before committing, as required by
`AGENTS.md`.

Keep Lean's bundled Clang out of the native test `PATH`; setup exposes it only
while building the kernel. The test runner needs only the downloaded Bend and
the explicit `BENDTT` kernel path.

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

## CI and releases

`.github/workflows/ci.yml` runs on pull requests, pushes to `main`, manual
dispatch and Mondays at 04:23 UTC. Each job provisions its own checkout without
restoring tools, binaries or a venv from a cache:

| Job | Coverage | Environment |
| --- | --- | --- |
| `fast` | CLI, known distances, all listed word boundaries, shrinking differential examples, regular proofs, release automation tests | Ubuntu 24.04 / system Python 3.12 |
| `extended` | Full suite with exhaustive binary strings, 100 property examples, long ASCII, carries, padding, 1/2/4 threads, regular and kernel proofs | Ubuntu 22.04 / Python 3.10 and Ubuntu 24.04 / Python 3.12 |
| `benchmark` | Fresh native builds, validated corpus, five repeats with 1 and 4 Bend threads | Ubuntu 24.04; pushes, schedule and manual runs |

Test reports, tool/package versions and benchmark CSVs are retained as workflow
artifacts. Benchmark timings include startup and carry no speed thresholds.
Extended jobs depend on the fast gate and run independently in a matrix;
benchmark work runs alongside them. Pull requests receive read-only tokens.

After **every successful main-push CI run**, `.github/workflows/release.yml`
publishes a tag and GitHub Release named `build-<CI-run-number>-<short-SHA>` at
the exact tested commit. Failed CI produces no release; rerun the failed run
after resolving transient failures. A rerun reuses the same tag/release. Main
push runs are never canceled by a newer push. Only the release job receives
`contents: write`; the repository's normal `GITHUB_TOKEN` is sufficient, with
no personal access token or additional secret. Repository tag rules must allow
the Actions token to create `build-*` tags.

Release notes combine GitHub's generated PR/contributor notes, **every commit
subject since the nearest published release on main's ancestry**, a comparison
link and a changed-file summary. Direct commits and multi-commit pushes are
included. The first release lists the full history. An overlapping newer run
cannot become an older run's changelog base. These are source releases with
GitHub's source archives, not packaged native library binaries. GitHub source
archives omit submodule contents; clone the release tag and run setup to obtain
the recorded Edlib revision.

Preview the commit/file portion locally without creating tags or contacting
GitHub:

```bash
GH_REPO=jware-solutions/bend-edlib python3 scripts/release.py --dry-run
# Optional range: add --previous-tag build-123-01234567
cat build/release-notes.md
```

## License

bend-edlib is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
You may use, modify and redistribute it under the terms in [LICENSE](LICENSE).
Redistributed modified versions must remain under GPL-3.0, and distributed
binaries must be accompanied by access to the corresponding source as the
license requires. The software comes without warranty, to the extent permitted
by applicable law.

The vendored C++ Edlib dependency retains its
[MIT license](vendor/edlib/LICENSE) and copyright notice.
