# Contributing to bend-edit-distance

## Development environment

The project pins Bend in `.bend-version`, Lean in `.lean-version`, and Python
packages in `requirements-test.txt`. `scripts/tools.sha256` contains the expected
SHA-256 digests of the downloaded Bend and Lean release archives. Setup verifies
them before extraction.

On Debian/Ubuntu:

```bash
bash scripts/setup.sh
export PATH="$PWD/build/tools/bend/bin:$PATH"
export CC=clang-19 BENDRTS=
```

Setup installs native dependencies, initializes Edlib at its recorded gitlink,
installs the pinned tools, builds the proof kernel and creates `build/test-venv`.
`--native-only` skips Lean and the kernel; `--skip-system` skips package installation.
The script replaces its tool installations and recreates the test environment.
Other environments can provision compatible tools separately. Windows Python
entry points forward commands to WSL.

Native CPU builds require Clang 14+; GPU builds require Clang 19+. The runners
select the project-local Bend, verify its version, select `clang-19` when `CC`
is unset, and reject an invalid explicit compiler. They clear `BENDRTS` for
reproducible runs. Keep Lean's bundled compiler out of the native build PATH.

The proof kernel lives in `build/tools/kernel`. Its `toolchain.json` records the
Bend/Lean pins and hashes of the distributed source, compiled source and binary.
`--verdict` requires this kernel rather than a user cache. Rebuild it with setup
when changing the proof toolchain.

## Library and executable interfaces

`lib.bend` exports the pure library: `distance`, `default_config`, `align`,
`align_batch`, and `alignment_to_cigar`. Public data types live in `EdlibTypes.bend`.
Examples are in `examples/`.

```bash
mkdir -p build
bend worker.bend -o build/bend-edit-distance
build/bend-edit-distance +RTS --threads 1 -RTS --RTS ACGT ACG
build/bend-edit-distance +RTS --threads 4 -RTS --RTS --config HW PATH -1 '' EXTENDED AC TACGAC
```

Native runtime options belong between `+RTS` and `-RTS`. The following `--RTS`
is removed and protects all application arguments, including literal `+RTS`,
`-RTS`, `--RTS`, and `--`. A plain `--` is application data. `IO.args` includes
`argv[0]`. `BENDRTS` supplies defaults overridden by command-line runtime options.
The driver uses its separate `bend file.bend -- args` convention. Python benchmark
scripts have their own `--threads` option.

The text CLI accepts two non-NUL ASCII strings, up to 4096 characters each.
Configured calls accept mode, task, threshold, concatenated equality pairs,
CIGAR format, query and target. Invalid calls exit 2 and write to stderr.
Binary workers support all 256 byte values and explicit lengths; see
[TRANSPORT.md](TRANSPORT.md) for BED1/BER1 compatibility, prepared queries, batches and the Python adapter.

Preserve these Edlib semantics:

- Modes NW, SHW and HW; tasks DISTANCE, LOC and PATH.
- Inclusive distance thresholds; negative thresholds mean unlimited.
- Literal equality plus symmetric, non-transitive configured pairs.
- Empty-input behavior, coordinate sentinels and ordered optimal locations.
- Insertions consume query; deletions consume target.
- PATH describes the first interval; CIGAR supports STANDARD and EXTENDED.
- Missing optional fields remain distinct from present empty fields.

## Architecture

- `src/Profile.bend`, `src/BitVector.bend`, `src/Workspace.bend` and
  `src/SearchKernel.bend`: compact byte masks, 32-bit transitions and owned bands.
  `src/Myers.bend` dispatches modes and retains the general String fallback.
  Block carries and successive columns are sequential.
- `Prepared.bend`: fixed query masks, per-call options and explicit owned clones.
- `src/DistanceDP.bend`: independent unit-cost dynamic programming reference.
- `src/Reconstruction.bend`: DP traceback and Hirschberg. Forward/reverse rows
  are independent; subpaths run sequentially to bound memory.
- `src/Batch.bend`: cached job lengths, contiguous homogeneous plans, weighted
  mixed plans, serial leaves and checked indexed result gathering.
- `GpuBatch.bend`: one bang around execution of a prepared batch; planning and
  result ordering remain on the host.
- `src/Cli.bend`, `src/ByteProtocol.bend`, `src/Transport.bend` and
  `src/transport.c`: text validation and binary executable boundary. Foreign
  effects remain outside the pure library.

Prepare recursive arguments before parallel calls. Copying a value can make
all nodes of its datatype count fields; removing an isolated `+` is insufficient
proof of cheaper ownership. Inspect emitted C and measure representative work
before changing data layouts or parallel granularity.

## Algorithm validation

```bash
bend guide
bend guide shaders
bend PROOF.bend
python3 run_tests.py -v
python3 run_tests.py --alignment -v
python3 run_tests.py tests/test_proofs.py --verdict -v
```

The suite tests edit distance, alignment, locations, paths, CIGAR, equality pairs,
thresholds, byte inputs and batch ordering. It compares results with vendored
C++ Edlib and checks algorithm properties and formal laws. It does not test
release automation, runtime option parsing, benchmark statistics or tool setup.
`--alignment` enables the exhaustive and extended property cases. Fixtures rebuild
native binaries once per run; helpers retain persistent workers for repeated calls.

Compare distance and locations with Edlib. When implementations choose different
optimal paths, check input consumption, operation orientation, total cost and
CIGAR validity rather than requiring an identical tie break. Exact upstream
fixtures remain in `tests/regressions/`.

Keep algorithm specifications in `LAWS.bend` and corresponding proofs in
`PROOF.bend`. Add laws for behavioral changes without weakening existing domains.
Run `bend PROOF.bend` before committing. Kernel verification covers translated
pure terms; native effects and backend execution require differential tests.

## Benchmarks

```bash
python3 run_benchmarks.py --repeats 7 --warmups 2 --batch-size 16 --threads 1 2 4
python3 run_gpu_benchmarks.py --check-build
python3 run_gpu_benchmarks.py --case example --threads 4 --output build/gpu/example
python3 -m benchmarks.compare_toolchains \
  --baseline /path/to/baseline/bin/bend \
  --candidate /path/to/candidate/bin/bend \
  --threads 1 2 4 --warmups 2 --repeats 7 \
  --output build/benchmarks/toolchains-example
```

Use the fixed input corpus in `benchmarks/corpus.json`, identical CPU affinity
and thread counts, discarded warmups and interleaved repetitions. Separate
compilation, execution, total latency, throughput and memory. CPU benchmarks also
provide prepared-profile and lookup/scan controls. Timing results are observations,
not correctness assertions.

GPU measurements require forced device execution, a newly generated sidecar and
completed device work. The instrumentation rejects unknown runtime structure.
`device_completed_bangs` counts drained bangs; `device_sync_batches` counts
successful CUDA synchronization batches; `device_rounds_submitted` includes
submitted rounds that may have no work. Scheduler wall time includes launch,
synchronization and implicit migration. Prefetch durations and requested bytes
are separate from scheduler and total time; requested bytes are not PCIe traffic.
Memory samples are device-wide observations, not exact per-process peak VRAM.
The CPU comparison uses a separate no-bang executable.

Generated results belong in ignored `build/` or `benchmarks/results/` directories.
Commit reusable benchmark source and the fixed input corpus, not reports, samples,
logs or experimental variants.

## CI and releases

CI provisions each job independently. CPU jobs run the algorithm suite; the
proof job builds Lean/BendTT and verifies the algorithm laws. Benchmarks keep
results as workflow artifacts. The manual GPU workflow requires a provisioned
CUDA runner and executes device alignment comparisons.

After successful main-push CI, the release workflow publishes `version.txt` at
the tested commit. Preview release notes locally with:

```bash
GH_REPO=jware-solutions/bend-edit-distance python3 scripts/release.py --dry-run
```

Publish the Bend library explicitly with:

```bash
bend lib.bend --publish bend-edit-distance@<version>
```

Keep the public package version consistent with `version.txt`. Publishing and
version changes must be requested separately from implementation work.

## License

This project uses GPL-3.0; see [LICENSE](LICENSE). Vendored Edlib retains its
[MIT license](vendor/edlib/LICENSE).
