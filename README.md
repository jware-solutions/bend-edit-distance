# bend-edit-distance

A Bend implementation of Edlib's edit-distance and alignment features.

> [!NOTE]
> This project is a work in progress. It does not yet provide complete Edlib
> functionality, and performance may not be optimal.

## Setup

Install Bend 2.0.36 or newer. On Windows, use WSL. On Linux or WSL, the official installer is:

```bash
curl -fsSL https://bend-lang.com/install.sh | sh
```

## Usage

### Command line

From the repository root in Linux or WSL, compile and run the CLI:

```bash
mkdir -p build
bend worker.bend -o build/bend-edit-distance
build/bend-edit-distance --threads 1 -- ACGT ACG
```

The command prints the global edit distance (`1` for this example).

For JSON results, specify mode, task, threshold (any negative value for unlimited),
concatenated equality pairs and CIGAR format:

```bash
build/bend-edit-distance --threads 1 -- --config HW PATH -1 '' EXTENDED AC TACGAC
```

DISTANCE includes end locations; LOC adds starts; PATH adds operation codes and
CIGAR. Missing distance and the coordinate before zero serialize as `-1`.
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
[typed API](CONTRIBUTING.md#typed-alignment-api) for the complete result contract.

### From another Bend file

Import its library module from any Bend file:

```bend
import Base
import bend-edit-distance@0.1.0.0/lib.bend as Edlib

def main() -> Nat:
  Edlib.distance("kitten", "sitting")
```

Bend resolves and caches the package from the Hub on import. The full configured API is available through `Edlib.align`, with `Edlib.default_config()` for the default NW distance setup.

See [examples/library_usage.bend](examples/library_usage.bend) for a local library usage example.

## Contributing and development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, implementation notes, testing and proof commands, benchmarks, and CI/release information.

## License

The project is licensed under [GNU GPL-3.0](LICENSE). The vendored C++ Edlib
dependency is under the [MIT license](vendor/edlib/LICENSE).
