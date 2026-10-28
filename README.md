# bend-edit-distance

A Bend implementation of Edlib's edit-distance and alignment features.

> [!NOTE]
> This project is a work in progress. It does not yet provide complete Edlib
> functionality, and performance may not be optimal.

## Setup

Use the pinned Bend 2.0.39. The setup script provisions Debian/Ubuntu development environments:

```bash
bash scripts/setup.sh
export PATH="$PWD/build/tools/bend/bin:$PATH"
export CC=clang-19 BENDRTS=
```

Setup verifies the release checksums, installs Lean 4.34.0, builds the project
proof kernel and provisions Clang 19+ for programs with `!`. The Python runners
select and check the project compiler automatically.

## Usage

### Command line

From the repository root, compile and run the CLI:

```bash
mkdir -p build
bend worker.bend -o build/bend-edit-distance
build/bend-edit-distance +RTS --threads 1 -RTS --RTS ACGT ACG
```

The command prints the global edit distance (`1` for this example).

For JSON results, specify mode, task, threshold (any negative value for unlimited),
concatenated equality pairs and CIGAR format:

```bash
build/bend-edit-distance +RTS --threads 1 -RTS --RTS --config HW PATH -1 '' EXTENDED AC TACGAC
```

DISTANCE includes end locations; LOC adds starts; PATH adds operation codes and
CIGAR. Missing distance and the coordinate before zero serialize as `-1`.
PATH describes the first reported start/end pair. Operation codes preserve
Edlib's convention: match `0`, insertion into target `1` (consumes query),
deletion from target `2` (consumes target), mismatch `3`. Every returned path
is checked for complete interval consumption, configured equalities and edit
cost equal to the reported distance. Small alignments use DP traceback; larger
ones use Hirschberg reconstruction with linear score storage. An optimal path
can differ from upstream's choice when several paths have the same cost.
Standard CIGAR uses `M/I/D` and merges adjacent matches and mismatches into
one `M` run. Extended CIGAR uses `=/X/I/D`, distinguishing matches under the
configured equalities from mismatches. Runs have positive decimal counts;
`I` consumes query and `D` consumes target. For example, operations
`[0,3,0,1,1,2]` become `3M2I1D` or `1=1X1=2I1D`.
Nonnegative thresholds are inclusive, including `k = 0`. Pinned Edlib's
empty-input early return ignores `k` and leaves starts/path/CIGAR absent.
NW aligns both complete sequences. SHW aligns the complete query to a target
prefix with a free suffix; HW aligns it to a target substring with both target
ends free. SHW/HW preserve query/target orientation and report every optimal
end location. DISTANCE uses Myers in all three modes, including configured
equality pairs. Pairs match in both directions and preserve literal equality.
They do not imply transitivity: configuring `N=A` and `N=C` still leaves `A`
and `C` unequal. Duplicate or reversed pairs have no additional effect.
The text CLI accepts non-NUL ASCII sequences up to 4,096 characters.
The [persistent byte workers](TRANSPORT.md) accept NUL and all 256 byte values,
use explicit sequence lengths, and process many requests in one executable.
Python adapters reuse these workers throughout a pytest session. See the
[typed API](CONTRIBUTING.md#library-and-executable-interfaces) for the complete result contract.

### From another Bend file

Import its library module from any Bend file:

```bend
import Base
import bend-edit-distance@0.2.2.0/lib.bend as Edlib

def main() -> Nat:
  Edlib.distance("kitten", "sitting")
```

Bend resolves and caches the package from the Hub on import. The full configured API is available through `Edlib.align`, with `Edlib.default_config()` for the default NW distance setup.

`Edlib.alignment_to_cigar(operations, format)` formats an existing path without
running alignment. Use operation and format constructors from `EdlibTypes.bend`;
an empty operation list produces `""` in either format.

`Edlib.align_batch(jobs)` executes independent `EdlibTypes.AlignJob{query,
target, config}` values on CPU in a tree grouped by estimated work. It returns
one complete result per job in input order, including for mixed sizes and
configurations. Compile [examples/batch_usage.bend](examples/batch_usage.bend)
and run with `+RTS --threads 1 -RTS --RTS` (or 2/4 threads). See the
[batch API details](CONTRIBUTING.md#architecture).

The local `lib.bend` also exposes `prepare(query, equalities)`,
`align_prepared(prepared, target, options) -> (prepared, result)`,
`align_prepared_batch`, and `clone_prepared`. Options use `Prepared.Options`
from `Prepared.bend`, or `default_prepared_options()`. Keep the returned owner
for the next call. Preparation fixes the profiled query, equalities and word
width; concurrent shards require independent owners. The Python worker offers
[prepared handles and batches](TRANSPORT.md#prepared-queries-and-batches-bed2).

For GPU batches, import `./GpuBatch.bend` and call `align_batch(jobs)`; see
[examples/gpu_batch_usage.bend](examples/gpu_batch_usage.bend). The separate
module keeps CPU consumers independent of the GPU toolchain. It prepares the
plan on CPU, executes one `!` call, and restores result order on CPU.
`gpu_batch.bend` accepts a count or `--worker` for persistent BED1/BED2 requests.
Prepared GPU batches retain independent profiles/workspaces and execute in
bounded waves; `prepare_query` and `align_prepared_batch` expose the owned API.
Force `+RTS --gpu on -RTS` when requiring hardware execution: Bend's default can fall
back to CPU. [GPU validation and benchmarks](CONTRIBUTING.md#benchmarks)
require completed device dispatches, compare complete CPU/GPU results, and
measure transfers, observed VRAM and the batch-size crossover.

See [examples/library_usage.bend](examples/library_usage.bend) for a local library usage example.

## Contributing and development

The public CPU API is [lib.bend](lib.bend), with canonical types and constructors
in [EdlibTypes.bend](EdlibTypes.bend). [GpuBatch.bend](GpuBatch.bend) is the explicit
GPU API. The compatible `main.bend`, `worker.bend` and `gpu_batch.bend` entries
delegate to the flat implementation modules in `src/`. See the
[source layout and preserved contracts](CONTRIBUTING.md#architecture).

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, implementation notes, testing and proof commands, benchmarks, and CI/release information.

## License

The project is licensed under [GNU GPL-3.0](LICENSE). The vendored C++ Edlib
dependency is under the [MIT license](vendor/edlib/LICENSE).
