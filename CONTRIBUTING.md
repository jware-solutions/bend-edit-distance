# Contributing to bend-edit-distance

This guide contains the setup, implementation, testing, proof, benchmark, CI, and release details for contributors.

## Development setup and tests

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
git clone https://github.com/jware-solutions/bend-edit-distance.git
cd bend-edit-distance
bash scripts/setup.sh
python3 run_tests.py --alignment --verdict -v
```

`bash scripts/setup.sh --native-only` omits Lean and the proof kernel for the
fast and benchmark tiers. Add `--skip-system` only when the apt prerequisites
are already installed. Setup replaces its tool installations and clears the
test venv on every invocation. No preexisting Bend, Bun, Lean, elan, Edlib CMake
build, or user proof-kernel cache is needed. The runner gives the project tools
priority over system installations and selects the project kernel explicitly.

Every run rebuilds the native binaries to include edits to `worker.bend`, the
DP entry point and their imports. The fixtures compile each executable only once per session. Build
failures, process failures, invalid output and timeouts fail tests with command
diagnostics. Build products and the Python environment stay under ignored
`build/`; no existing Edlib CMake build is needed.

## BendHub library package

`lib.bend` is the public package entry point. It exports `distance` for the
simple NW distance API, `default_config` and `align` for structured alignment
results. Run `bend examples/library_usage.bend` to try the API from a separate
Bend file using a local checkout. Consumers do not need the Python test setup;
after publication, Bend resolves the package directly from the Hub import.

### Publishing

To publish a new version of the library to BendHub, follow these steps:

1. Ensure all tests pass and the library is ready for release.
2. Update the version in `lib.bend` and any relevant documentation.
3. Use the Bend CLI to publish the package:

   ```bash
   bend lib.bend --publish bend-edit-distance@<version>
   ```

4. Verify that the version is the same as the one in `version.txt` file.
5. Ensure the package is available on BendHub and that the version is correct.

## Alignment protocol

The two-argument `main.bend` CLI returns the global Levenshtein edit distance:

```text
build/bend-edit-distance --threads 1 -- ACGT ACG
1
```

The default suite compares all three algorithms on known distances, normal and
empty arguments, whitespace, literal shell characters, arguments resembling runtime flags, two CPU threads,
invalid argument counts, Unicode and length-limit rejections, the C++ oracle,
subprocess error handling, 32-bit word boundaries, 20 deterministic Hypothesis
examples (plus explicit regressions), release-note generation, and
`bend PROOF.bend`. `--alignment` adds the extended differential/property suite;
`--verdict` also checks proofs with the Lean-backed kernel.

`IO.args()` includes the program name in this compiler version. Keep the
`Con{_, Con{query, Con{target, Nil{}}}}` pattern in `run`. Text CLI invocations place
`--` before the sequences so strings such as `--threads` reach the program
unchanged. Python alignment adapters use the binary worker. The legacy CLI
requires exactly two sequences. The configured CLI
requires the fixed argument list described below; other counts exit 2.

The text CLIs in both native Bend executables validate each sequence before computing a distance:

- Characters must be **non-NUL ASCII (U+0001 through U+007F)**. Whitespace,
  control characters, DEL and strings resembling runtime flags are allowed.
  Non-ASCII characters are rejected even when both strings are identical or
  the other string is empty. UTF-8 text is not interpreted as byte input.
- Each sequence may contain **0 through 4,096 characters**, inclusive. This is
  an application limit per argument, not a limit on the sum of their lengths
  or on the edit distance. On supported inputs ASCII characters are one byte.
- Unsupported characters or excessive lengths exit **2**, write a diagnostic
  to **stderr**, and leave **stdout empty**. Invalid argument counts use the
  same error protocol. For example, `build/bend-edit-distance -- Ā Ā` reports an ASCII
  error instead of a distance.

The 4,096-character cap bounds query-profile allocation and alignment work:
Myers advances at most `4096 * 128` blocks, and the DP test executable computes
at most `4096 * 4096` cells. It also keeps scores well inside `U32` and arguments
below the tested WSL/Linux transport limits. This is a conservative supported
size, not a universal latency guarantee. `Cli.bend` validates both inputs in
parallel with bounded scans (at most 4,097 characters per sequence), before
either algorithm or its empty-input shortcuts run. Workers use explicit byte
lengths and bypass this CLI validation. The pure Myers distance function requires
byte-valued characters; its table indexes the low eight bits of each character.

## Implementation

The Myers implementation in `main.bend` ports the distance path from the
vendored `edlib.cpp`:
`build_peq`/`build_peq_word` build equality masks, `calculate_block` advances a
Myers bit-vector block, `get_block_cell_value` removes wildcard padding from the
final score, and `myers_calc_edit_distance_nw` advances the global alignment.
`distance` handles empty inputs and selects the shorter sequence as the query.
That swap is confined to NW: SHW (prefix) and HW (infix) retain the original
query as the bit-vector axis, even when it is longer than the target.

Blocks use native `U32` words with 32 query positions, adapting Edlib's 64-bit
words. Immutable byte-indexed query tables are built with balanced parallel
calls; the two input lengths are also computed in parallel. Blocks within a
column and consecutive columns remain sequential because their carries depend
on the preceding calculation. NW/DISTANCE uses a block-level Ukkonen
band: finite `k` rejects impossible length differences before profile creation,
initializes only active blocks, expands by at most one block per column, prunes
both ends and stops if the band collapses. Conservative block bounds are ported
from pinned Edlib with 32-bit constants and nonnegative `Nat` inequalities.
Wildcard padding is added back when tightening `k` and removed from the final
score. Unlike Edlib, there is no periodic per-cell strong reduction.

Unlimited NW starts at `min(n, max(32, n-m))`, doubles the threshold after a
failed attempt and caps it at `n`, an upper bound on unit-cost NW distance.
Retries reuse the immutable profiles and initialize fresh block states. Only
the active column and query profiles are retained, without traceback storage.
`tests/myers_probe.bend` observes production block calls, consumed columns and
attempts; tests verify pruning of both ends, immediate length rejection, early
band collapse, adaptive retries, every padding size and threshold boundaries
against independent scalar Bend DP and pinned C++ Edlib, including raw bytes.

SHW/HW DISTANCE uses `myers_calc_edit_distance_semiglobal`. Both
initialize query scores to `i`; the first horizontal carry is +1 for SHW and
zero for HW. A separate band initializes at most `ceil((k+1)/32)` blocks and
expands by at most one block per target column. It prunes trailing blocks using
their vertical score bound, without NW's remaining-target constraints. HW
retains block zero and scans the entire target so later matches survive bad
prefixes. SHW may stop when its band collapses. Unlimited searches start at
query length, an upper bound obtained by deleting the query. Finite thresholds
are capped at that bound before band setup; every optimal end is collected,
including ties after the threshold tightens to zero. Padding is decoded at
each target column. The pinned Edlib column-zero convention still uses its
64-bit query lengths, independently of Bend's 32-bit padding.

`tests/test_semiglobal.py` compares directional distance and all end locations
against independent Bend DP and pinned Edlib for both input orders, empty
inputs, free target ends, repeated matches, thresholds and every padding size.
At `k = INT_MAX`, pinned Edlib's semiglobal initialization overflows `k+1`;
Bend retains inclusive threshold semantics and checks that case against DP.

`DistanceDP.bend` independently exports `distance(query, target) -> Nat` and
configured DISTANCE `align(query, target, config)` for all three modes. It imports
only `Base` and the result types, with no Myers or configured-DP dependency.
It implements the two-row Levenshtein recurrence:

```text
D[0,j] = j; D[i,0] = i
D[i,j] = min(D[i-1,j] + 1, D[i,j-1] + 1,
             D[i-1,j-1] + !equal(pairs, row[i-1], column[j-1]))
```

For NW, the shorter sequence supplies the columns, so both rows have
`min(m, n) + 1` cells. Directional modes keep target columns and use `n+1`
cells: SHW keeps `D[0,j]=j`, HW uses `D[0,j]=0`, and both minimize `D[m,j]`
to free the target suffix. Each row consumes its predecessor; no distance matrix
or traceback is retained. For a fixed pair list this takes `O(m*n)` time,
with `O(min(m,n))` score storage for NW and `O(n)` for SHW/HW. Matching scans
the pair list, adding a factor of `p+1` for `p` configured pairs.
Scores use `U32`, as in Myers. Input
lengths are computed in parallel;
cells and rows remain sequential because each depends on its predecessor.
`EdlibTypes.equal` supplies the same literal-or-symmetric-pair predicate for
independent DP, configured traceback and Myers profile construction. Pairs
never form transitive equivalence classes: `N=A` and `N=C` leave `A` and `C`
unequal. Duplicate, reversed, self and absent-symbol pairs are allowed; byte
workers preserve all pair values, including NUL and bytes above 127. Profile
padding remains wildcard regardless of the pairs. `tests/test_equalities.py`
compares all three distance implementations, checks profiles for all 256 byte
values and covers thresholds, word boundaries, locations and traceback.
The scalar CLI continues to use Myers. Tests compile `tests/distance_dp.bend`
as `build/bend-distance-dp`, which calls DP directly with the same CLI contract.

`LAWS.bend` states the claims and input domains; `PROOF.bend` supplies their
proofs. In addition to the empty-input, mask, DP recurrence and CLI laws, the
incremental invariants cover:

| Invariant | Quantified domain |
| --- | --- |
| Splitting rejoins to the original string; prefix length is `min(size, length)` | Every Bend `String` (including Unicode), every `Nat` size |
| Initial block count; DP initial/updated row widths | Every `Nat` count, every `String`/previous row and `U32` accumulator; these are structural claims |
| No-padding decoding preserves the score | Every pair of `U32` bit vectors and every `U32` score |
| Outgoing carry is independent of stored score | Every `U32` mask, pair of scores and incoming `Carry`, including unreachable states |
| Uniform-word carry propagation | All three valid incoming signs, every `U32` score, all-match/all-mismatch equality words, and vertical bit vectors `(all ones, 0)` or `(0, all ones)` |
| CLI support, identity and Myers/DP equivalence | Exactly all seven strings of length 0..2 over `{'A', 'a'}`; equivalence covers all 49 ordered pairs |

Carry claims cover these block families even when the score is not reachable;
they certify the outgoing sign, not arbitrary block states or nonwrapping score
arithmetic. The bounded alignment domain is encoded by `SmallAscii`, so it
cannot accidentally include Unicode. Three-way differential tests check the
broader supported distance behavior.

## Limitations

The supported contract is byte alignment (including NUL) with unit edit costs,
NW/SHW/HW modes, DISTANCE/LOC/PATH tasks, thresholds and additional equalities.
The project implements part of Edlib's behavior.
The following features and checks are still missing from this repository:

- **Configured alignment performance:** locations and paths use a scalar
  recurrence with two score rows. DISTANCE uses Myers even with custom equality
  pairs; profile construction scans the configured pairs for each symbol match.
  PATH retains shared operation prefixes and recomputes NW for the first
  matching interval.
  Thresholds filter the final optimum; they do not prune the DP computation.
  General optimality proofs and acceleration for these scalar paths remain future work.
- **Large alignment cost:** persistent workers remove text/argv limits, but
  configured scalar alignment can still require quadratic work and substantial
  memory. Protocol frames use Edlib's signed length range. The legacy text CLI
  retains its conservative ASCII/4,096-character limit.
- **Correctness coverage:** independent DP cross-checks Myers and C++ Edlib,
  including the exhaustive small-input matrix, shrinking properties, direct
  masks/block checks and upstream NW regressions described below. This is
  finite test coverage; continuous fuzzing and general correctness proofs
  remain future work. Extended alignment tests require `--alignment`;
  known-distance, word-boundary, case, motif, unequal-length, upstream regressions
  and small Hypothesis comparisons run by default. CI explicitly runs both tiers.
- **Proof coverage:** the table above states the exact quantified domains.
  Identity and Myers/DP equivalence are proved only for the seven-string ASCII
  domain; carry propagation is proved only for the specified uniform-word
  families. General identity over all Bend `String` values would be false for
  Myers because the query table is byte indexed. General equivalence, correctness
  of arbitrary reachable carries and optimality for arbitrary lengths remain
  future work. The ordinary checker runs by default; the mandatory CI `proofs`
  gate provisions Lean 4.34.0 and runs `--verdict` independently of the extended
  differential suite. Kernel checking retains the verification limits below.
- **Performance and batching:** the benchmark runner below records phase timings,
  one-core latency, homogeneous batch throughput and whole-process peak RSS
  against C++ Edlib. Measurements are host/workload observations, not a general
  speedup claim. Ordinary NW/DISTANCE uses threshold bands,
  early rejection and adaptive retries. Parallelism currently covers
  preprocessing for one pair; balanced benchmark batches are benchmark-only.
  There is no production CPU batch API, GPU entry point or
  genuine-device test. Tests with multiple CPU threads check correctness only.
- **Library and release readiness:** `lib.bend` provides a stable Bend import
  surface for the current distance and configured-alignment APIs. Its first
  BendHub name/version is prepared in the documentation but has not been
  published. A broader platform compatibility matrix remains to be established.
  CI, clean-checkout tool setup and versioned source
  releases are automated as described below.

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

Persistent [byte workers](TRANSPORT.md) support NUL and all 256 byte values,
including equality pairs. Typed missing-result values, modes, thresholds,
equalities, locations, paths and CIGAR use the same result contract. The legacy
text CLIs retain the ASCII/4,096-character domain.

## Typed alignment API

`main.edlib_align(query, target, config) -> EdlibTypes.AlignResult` accepts an
`AlignConfig` containing mode, task, threshold, equality pairs and CIGAR format.
`EdlibTypes.default_config()` selects NW, DISTANCE, unlimited threshold,
ordinary equality and extended CIGAR. `main.distance(query, target) -> Nat`
retains the scalar NW helper used by existing proofs and benchmarks.

`EdlibTypes.bend` defines separate `Found{Nat}`/`NotFound{}` distance values,
`Position{Nat}`/`BeforeStart{}` coordinates, status and operation constructors.
Absent starts/path/CIGAR use `None{}`; a present empty path is `Some{Nil{}}`.
The serializer converts `NotFound{}` and `BeforeStart{}` to Edlib's `-1`.

The configured text CLI and C++ oracle retain the same convenience argument protocol:

```bash
build/bend-edit-distance --threads 1 -- --config HW PATH -1 '' EXTENDED AC TACGAC
build/edlib-oracle --config HW PATH -1 '' EXTENDED AC TACGAC
```

```json
{"status":0,"edit_distance":0,"end_locations":[2,5],"start_locations":[1,4],"alignment":[0,0],"cigar":"2="}
```

Modes are NW (global), SHW (prefix), HW (infix). DISTANCE returns all optimal
end locations, LOC adds their corresponding starts, and PATH adds an alignment
for the first interval. Operation codes are 0 match, 1 insertion into target
(consumes query), 2 deletion from target (consumes target), 3 mismatch. Standard
CIGAR merges matches/mismatches as `M`; extended CIGAR uses `=`/`X`.

Threshold accepts Edlib's signed 32-bit range; every negative value means
unlimited and every nonnegative value is an inclusive maximum. `k=0` accepts
only exact matches on nonempty inputs. A distance
above the threshold has OK status, `edit_distance: -1`, empty end locations
and null starts/path/CIGAR. Equality-pair text concatenates two-character
pairs (for example `aANACN` declares a=A, N=A, C=N); pairs are symmetric and
do not imply transitive equality. The CLI allows up to 2,048 pairs of single
non-NUL ASCII characters. Literal argv transport preserves whitespace and
characters resembling flags, including within equality pairs.

Python configuration and result types live in `alignment.py`; the persistent
binary codec and process owner live in `transport.py`. The adapters reuse one
worker per executable/thread configuration and close them at session teardown:

Use `threshold_from_edlib(k)` to convert an integer to the typed `Unlimited()`
or `MaxDistance(k)` representation. Unlimited serializes canonically as `-1`;
the native CLI and wire decoder also accept every other negative `i32` value.

```python
from alignment import AlignConfig, Mode, Task, MaxDistance, EqualityPair
from tests.helpers import bend_align, cpp_edlib_align

config = AlignConfig(mode=Mode.HW, task=Task.PATH, threshold=MaxDistance(1),
                     equalities=(EqualityPair("a", "A"),))
actual = bend_align(b"aC", b"TaCG", config)
expected = cpp_edlib_align(b"aC", b"TaCG", config)
assert actual == expected
assert actual.require_distance() == 0
assert actual.to_edlib()["end_locations"] == [2]
```

Adapters return `AlignResult`, with typed distance/coordinates and optional
starts/operations/CIGAR. `to_edlib()` produces the wire dictionary;
`require_distance()` fails when no distance was found. Explicit scalar wrappers
are named `bend_distance`, `bend_dp_distance` and `cpp_edlib_distance`.
The oracle also accepts two sequences alone and returns structured default
DISTANCE results. The legacy Bend/independent DP CLIs continue printing a scalar.
Worker inputs are bytes; ASCII strings remain a convenience conversion. Encode
other text explicitly. Worker lengths are limited by the signed frame length
range and practical memory/work costs, rather than argv or the CLI size cap.
See [TRANSPORT.md](TRANSPORT.md) for field layouts, error recovery, explicit
worker ownership, byte equality pairs and lifecycle behavior.

Compatibility follows the pinned vendored Edlib, including its empty-input
early return: it ignores the threshold and leaves starts/path/CIGAR absent even
for LOC/PATH. `tests/regressions/upstream_empty.json` records all nine combinations
of empty query/target and mode, with distance and end coordinates independent
of the live oracle. Its semiglobal search omits the before-zero end location when
query length is a multiple of 64; configured Bend matches that behavior.
Valid PATH results can choose different optimal operations from Edlib on large
matrices (where Edlib uses Hirschberg); comparisons validate path cost and
consumption as well as exact distances/locations. Small deterministic paths
and CIGAR are compared exactly.

The default suite covers all modes/tasks, thresholds, symmetric/nontransitive
equalities, empty inputs, result sentinels, both CIGAR formats, malformed
configuration/results and word boundaries with 1/2/4 threads. `--alignment`
adds an exhaustive configured comparison for all 15 strings over `{A,C}` of
length 0..3 (2,025 mode/task/pair combinations). Typed serialization and
threshold laws are recorded in `LAWS.bend` and proved in `PROOF.bend`.

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
  tails via an injective ASCII relabeling; that migration includes only NW
  distance cases. Configured modes/results have their own oracle comparisons.

Most extended Hypothesis properties use 100 examples (40 for block traces), with replay,
generation and shrinking enabled, no timing deadline, and persistent reduced
failures in ignored `build/hypothesis/`. Re-run the same command to replay them.
Checked-in examples in `tests/regressions/nw.json` run both as explicit
distance regressions and Hypothesis `@example`s, even on a clean checkout.
See [the regression corpus notes](tests/regressions/README.md) for provenance
and how to preserve a newly discovered counterexample. The exhaustive matrix
reuses three persistent workers, avoiding per-pair process startup. Additional
byte tests cover all 256 values, NUL equality pairs, fragmented frames, invalid
configuration recovery, worker teardown and sequences beyond the argv limit.

Additional deterministic coverage runs 20 differential examples in the fast
suite and 100 extended examples with one, two and four CPU threads. The extended
checks cross-compare all three implementations for every derived pair, including
empty inputs, reversed inputs and common suffixes.

The scalar Bend/DP CLI contract is **NW/global Levenshtein distance**, unit costs,
unlimited threshold (`k = -1`), and one nonnegative decimal integer on stdout.
The C++ text oracle emits JSON. Python scalar helpers extract the distance from
structured binary responses and reuse workers for all three implementations.
Inputs are non-NUL ASCII strings of at most 4,096 characters each, so Edlib's
byte semantics match Bend's characters. Direct native CLI tests cover Unicode
rejection in either argument (including empty counterparts), every non-NUL
ASCII character, and accepted/rejected length boundaries on one and two threads.
The CLI bridge cannot transport NUL bytes and has operating-system argument
length limits; [persistent workers](TRANSPORT.md) provide the byte API.
Prefix/infix modes, thresholds and paths use the configured protocol
and comparisons in `tests/test_configured_alignment.py`.

Add cases to `tests/test_alignment.py`, or create your own tests using the
session fixtures and adapters:

```python
import pytest
from tests.helpers import bend_distance, bend_dp_distance, cpp_edlib_distance

@pytest.mark.alignment
def test_my_case(bend_binary, dp_binary, cpp_binary):
    query, target = "ACGT", "AGT"
    expected = cpp_edlib_distance(query, target, binary=cpp_binary)
    assert bend_distance(query, target, binary=bend_binary) == expected
    assert bend_dp_distance(query, target, binary=dp_binary) == expected
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
the explicit `BENDTT` kernel path. Setup records the Bend/Lean pins and SHA-256
hashes of the kernel source and executable in `build/tools/kernel/toolchain.json`.
Requesting `--verdict` requires this executable and matching provenance; a
missing, modified or stale project kernel fails with setup instructions. Both
the runner and direct pytest select it explicitly, even if `BENDTT` previously
pointed at a user cache. A negative-control test confirms that a rejecting
kernel is actually invoked and makes verification fail.

The `tests.compare` helper reports DP/Myers/Edlib persistent-worker request times
after tests rebuild their executables:

```powershell
wsl --exec python3 -m tests.compare --repeats 5 --threads 1
```

Inside WSL, use `python3 -m tests.compare` with the same options. The report is
CSV with one shared distance and median milliseconds for DP, Myers and C++
Edlib. It validates every result, uses seed `20261008`, warms each binary once
per pair, and rotates invocation order. These are **warmed request wall times**,
including binary transport, alignment and response decoding, excluding process
and runtime startup. The corpus includes all byte values. Timing differences
are observations, not test pass/fail thresholds. The phase benchmarks below
retain their separate startup/argv instrumentation.

## Reproducible performance benchmarks

From PowerShell at the project root, after native tools and the Edlib submodule
are available (use `python run_tests.py --setup` for a fresh environment):

```powershell
python run_benchmarks.py --repeats 5 --batch-size 16 --threads 1 4
```

Windows automatically forwards to WSL. Inside WSL/Linux, the same command is
`python3 run_benchmarks.py ...`; only the Python standard library is needed.
For a fresh Linux checkout, `bash scripts/setup.sh --native-only` provisions the
tools first. The runner verifies `.bend-version` and rebuilds its own native
executables every run in `build/benchmarks/`. It compiles Edlib with
`g++ -std=c++14 -O2 -DNDEBUG` (override the compiler with `CXX`); Bend uses its
normal pinned native backend. Build times are recorded separately from runtime.
It does not require running the exhaustive correctness suite to build benchmarks.

The checked-in [corpus](benchmarks/corpus.json) contains 16 named ordered pairs:
empty inputs, the standard edit-distance example, 31/32/33 and 63/64/65 word
boundaries, similar and independent DNA, repetitive motifs, non-NUL ASCII,
4,096-character DNA, and a 3-versus-4,096 pair in both orders. Expected distances
come from independent scalar DP. `python3 benchmarks/generate.py` regenerates
the exact collection with xorshift32 seed `20261009`; an integrity test checks
that regeneration matches. The runner hashes the corpus and validates every
single-pair/batch checksum, including warmups, against its expected distance;
lookup checksums are independently computed in Python. A disagreement, invalid
output, nonzero exit or timeout fails the run and produces no successful report.

Each workload runs once as a discarded warmup and then five times by default.
Invocation order rotates across algorithms, modes and thread counts. Processes
run one at a time to avoid competing benchmark workers. One-thread Bend and
Edlib inherit affinity to the same single logical CPU. Multi-thread Bend inherits
the first N selected logical CPUs; Edlib remains single threaded. `--threads`
always includes 1. Choose cores deliberately on machines with SMT or hybrid CPUs;
`lscpu -e=CPU,CORE,SOCKET` shows WSL/Linux topology and `--cpus` sets the ordered
CPU list. The report records exact affinity, host topology, tool versions, source
and binary hashes, Git commit/dirty status, compiler commands and build durations.
No test or benchmark claims a speedup from correctness on multiple threads.

Workloads measure the same pair repeatedly within one native process. These are
**homogeneous batches**, not a persistent worker protocol or a mixed-query batch
API. Batch sizes are powers of two, 2 through 512. Bend splits independent
alignments into a balanced fork/join tree; columns/carries stay sequential. Edlib
runs the same number of independent alignments in a sequential loop.

| Workload | Timed work | Profile treatment |
| --- | --- | --- |
| `full`, batch size 1 | One-core native alignment latency, or the requested thread count | Each production `distance`/public `edlibAlign` call constructs/frees its own profile |
| `full`, batch size B | Full alignment throughput, B / work wall seconds | Constructs a new profile per pair, as production does |
| `prepared`, sizes 1 and B | Active-block initialization, banded columns, adaptive retries, decoding and runtime/refcount work | Builds one profile before timing work and retains it until the separate release phase |
| Bend `lookup`, size B | All target-symbol/block `peq_get` calls, with consumed mask checksums | Uses the unchanged 256-symbol trees, prepared before timing |
| Bend `scan`, size B | The matching target/block traversal with the tree lookup omitted | A control workload; no alignment distance is computed |

The prepared Edlib probe includes the unmodified vendored `edlib.cpp` in its
translation unit, allowing access to `buildPeq` and `myersCalcEditDistanceNW`.
It preserves the public NW distance algorithm's dynamic threshold retries from
64 upward, with no traceback. Alphabet transformation and equality setup occur
in the preparation phase. Bend chooses the shorter query internally; Edlib keeps
the original order, as the test oracle does. Their 32/64-bit words, band widths,
alphabet representations and starting thresholds differ. Prepared timings
exclude public API result/location packaging, so compare them separately from
the full public-call workload. They are benchmark entry points, not new APIs.

Native `CLOCK_MONOTONIC` barriers record each phase directly, with evaluated
values passed across them so profile construction cannot be optimized away or
charged to the alignment phase. Production alignment/table/lookup functions
remain unchanged. The measurements distinguish:

| Metric | Boundary / units |
| --- | --- |
| Launcher and native startup | Parent launch to small RSS launcher; native fork/exec to first entry-point effect, respectively; their sum is startup |
| Transport | `IO.args()` / materialization of argv strings after entry-point readiness; kernel argv copying is in startup |
| Preparation | Mode/count parsing, validation, orientation/lengths; Edlib prepared mode also transforms its alphabet |
| Profile construction | Direct Bend `build_peq` (256 symbols per 32-character word), or Edlib `buildPeq`; reported separately in prepared/lookup/scan modes |
| Work / release | Workload above, then persistent-profile release; `full` includes per-call profile construction and freeing within work |
| Native wall / end-to-end wall | Native fork to reaped worker; parent launch to reaped RSS launcher, respectively; E2E includes startup, transport, phases, output and teardown |
| CPU time / peak RSS | Worker user + system CPU time; worker's lifetime maximum resident set in KiB, including runtime and profiles, from native `wait4` |
| Latency / throughput | Work time / batch size in microseconds; B / work seconds and B / E2E seconds for full/prepared alignments |

The small C launcher forks from its own native address space to avoid inheriting
Python's memory high-water mark. Its overhead is included in E2E and separately
recorded; its own RSS is excluded from worker RSS. RSS is not a phase allocation
counter or reserved virtual memory. Timed phases include timer/IO scheduling
overhead, with no subtraction from another process run. Empty cases expose the
measurement floor; very small workloads and p95 values from five samples are
especially sensitive to scheduling. Warmups warm executable/filesystem caches;
each sample still starts a fresh process. CPU frequency, other host activity,
virtualization and filesystem placement can change results.

The lookup probe includes target/list traversal, reference counting and checksum
arithmetic. The scan control records that traversal separately, but their
difference is not an exact fraction of alignment time: the controls traverse
every profile while alignment visits the active band, and allocation/cache
behavior and Bend scheduling can differ. Use these measurements to investigate the
current table and tree before changing their representation. Thread scaling is
an observed per-workload ratio, never inferred from thread count alone.

Reports default to `build/benchmarks/results/`: `results.json` retains every raw
sample and median/min/max/nearest-rank-p95 statistics; `summary.csv` contains phase
times, peak RSS, per-pair latency and both throughput rates; `REPORT.md` compares
Bend work/E2E/RSS against Edlib. Existing result directories are protected from
overwrite. Select a fresh path and/or subset for later runs, for example:

```powershell
python run_benchmarks.py --case dna-random-512 --case dna-random-4096 --repeats 10 --batch-size 32 --threads 1 2 4 --output build/benchmarks/recheck
```

Use `--warmups 2`, `--timeout 180` or `--cpus 0,2,4,6` as appropriate for the host.
The checked-in [WSL observation](benchmarks/results/wsl-2026-10-09/REPORT.md)
includes its raw JSON and CSV alongside [interpretation of table/lookup costs](benchmarks/results/wsl-2026-10-09/NOTES.md).
It predates threshold banding and is one reproducible observation, not a
measurement of the current banded implementation or a portable performance guarantee.

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
| `proofs` | Regular and kernel proofs, kernel provenance checks and rejection control | Ubuntu 24.04 / pinned Lean 4.34.0 and freshly built BendTT |
| `extended` | Full suite with 14,641 exhaustive ordered pairs, shrinking properties, direct masks/block traces, regressions, 1/2/4 threads, regular proofs | Ubuntu 22.04 / Python 3.10 and Ubuntu 24.04 / Python 3.12 |
| `benchmark` | Fresh native builds, fixed validated corpus, phase timing/latency/batch throughput/RSS, five repeats with 1 and up to 4 available Bend threads | Ubuntu 24.04; pushes, schedule and manual runs |

Test reports, tool/package versions and benchmark CSVs are retained as workflow
artifacts. Benchmark reports include separate work and end-to-end timings and
carry no speed thresholds.
The fast and proof gates run independently. Extended jobs depend on both gates
and run independently in a matrix; benchmark work runs alongside them.
Pull requests receive read-only tokens.

After **every successful main-push CI run**, the `release` job calls `.github/workflows/release.yml` to publish the version in `version.txt` at the exact tested commit. An unpublished tag pointing to a different commit fails rather than being moved. Failed CI produces no release;  rerun the failed run after resolving transient failures. Main push runs are never canceled by a newer push. Only the release job receives
`contents: write`; the repository's normal `GITHUB_TOKEN` is sufficient, with
no personal access token or additional secret. Repository tag rules must allow
the Actions token to create `v*` tags.

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
GH_REPO=jware-solutions/bend-edit-distance python3 scripts/release.py --dry-run
# Optional range: add --previous-tag v0.1.0
cat build/release-notes.md
```

## License

bend-edit-distance is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
You may use, modify and redistribute it under the terms in [LICENSE](LICENSE).
Redistributed modified versions must remain under GPL-3.0, and distributed
binaries must be accompanied by access to the corresponding source as the
license requires. The software comes without warranty, to the extent permitted
by applicable law.

The vendored C++ Edlib dependency retains its
[MIT license](vendor/edlib/LICENSE) and copyright notice.
