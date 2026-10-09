# Interpretation of the WSL recording

Recorded on October 9, 2026 with Bend 2.0.36, Clang 14.0.6 and g++ 12.2.0,
Debian 12 / WSL2, on a reported Intel i7-1360P. One-core runs use logical CPU 0;
four-thread runs use 0, 2, 4 and 6, which have distinct core IDs in the reported
WSL topology. Virtualization does not guarantee exclusive physical host cores.
The checkout and executables are on `/mnt/c`; filesystem placement contributes
to startup. The sources were uncommitted; their exact hashes and Git status are
in [results.json](results.json), along with all 1,280 measured samples. There
were 256 workloads, five samples each, after one discarded warmup per workload.

Reproduce with the same corpus and explicit CPU selection (choose available
CPUs appropriate to a different host):

```bash
python3 run_benchmarks.py --repeats 5 --batch-size 16 --threads 1 4 \
  --cpus 0,2,4,6 --output build/benchmarks/wsl-reproduction
```

All distances and synthetic lookup/scan checksums matched the independent
corpus/Python expectations. See [REPORT.md](REPORT.md) for every comparison and
[summary.csv](summary.csv) for phases, throughput, latency and worker peak RSS.
The following values are medians, not speed thresholds.

## One-core work latency

| Pair | Bend full ms | Edlib full ms | Bend prepared ms | Edlib prepared ms |
| --- | ---: | ---: | ---: | ---: |
| Independent DNA, 512 × 512 | 4.3030 | 0.0443 | 0.6256 | 0.0292 |
| Independent ASCII, 1,024 × 1,024 | 7.7275 | 0.2164 | 2.9484 | 0.0672 |
| Independent DNA, 4,096 × 4,096 | 62.6238 | 1.1666 | 53.4745 | 1.1198 |

Full work includes profile construction/freeing, length scans and runtime
operations inside production alignment calls. Prepared work excludes input
preparation, profile construction and final persistent-profile release. Edlib
prepared work also excludes public API result packaging. These are different
workloads; their subtraction is not an exact allocation of full-call time.

## Profile construction and tree traversal

| Pair | Bend profile ms | Edlib profile ms | Bend lookup batch ms | Bend scan control batch ms |
| --- | ---: | ---: | ---: | ---: |
| DNA, 512 × 512 | 0.7204 | 0.0092 | 2.1103 | 0.4752 |
| ASCII, 1,024 × 1,024 | 1.4007 | 0.1226 | 12.1281 | 3.0184 |
| DNA, 4,096 × 4,096 | 5.5044 | 0.0657 | 211.9130 | 38.6891 |

Profile values come from **one** construction in the one-core prepared batch
workload; they are not per-batch totals. Lookup/scan values cover **16** repeated
target/block traversals on one core, with one previously built profile. The
4,096-character case executes 8,388,608 tree lookups in that lookup batch.
Construction and tree lookup are therefore measured candidates, with larger
absolute costs as lengths grow. At 4,096 characters, prepared alignment still
takes 53.4745 ms for one pair after profile construction has finished. Changing
the table alone cannot remove all that work.

The lookup probe includes string/list traversal, mask retention/reference
counting and checksum arithmetic. The scan control omits `peq_get` but keeps
the traversal. Its lower time helps motivate profiling the tree further;
subtracting these independent runs does not establish a precise percentage of
the real alignment loop or predict the benefit of a different representation.
The production 256-symbol construction and eight-level tree remain unchanged.

## Batch throughput, wall time and memory

For 16 independent 4,096 × 4,096 DNA alignments with a new profile per pair:

| Worker | Work ms | Alignments / work second | E2E ms | Alignments / E2E second | Peak RSS KiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bend, 1 core | 1,035.7684 | 15.45 | 1,052.9915 | 15.19 | 6,112 |
| Bend, 4 cores | 333.0838 | 48.04 | 354.5669 | 45.13 | 30,852 |
| Edlib, 1 core | 17.9946 | 889.16 | 31.0974 | 514.51 | 3,148 |

Four-core Bend full-batch work is 3.11 times faster than one-core Bend on this
case, with higher RSS. That scaling is measured, rather than inferred from
correctness tests. Single-pair full work did not improve on four cores
(70.0045 ms versus 62.6238 ms). Four-core Bend still takes 18.51 times as long
as single-core Edlib for the full batch here. The result establishes no Bend
speedup over Edlib, and no general scaling guarantee for other workloads.

## Measurement limits

Startup, argv materialization, preparation, profile construction, work and
release are separately recorded. E2E also includes the native RSS launcher,
output and final teardown. Whole-process peak RSS includes the runtime and
profiles; it is not alignment-only heap usage. The launcher's RSS and Python's
inherited memory high-water mark are excluded from worker RSS.

The full Bend empty-input work scope measured **3.0796 ms**, whereas the prepared
empty work scope measured **0.0010 ms**. The full scope has a substantial fixed
runtime/wrapper floor in this environment; do not interpret its tiny-input
ratios as pure edit-distance instruction costs or subtract that baseline from
other measurements. Prepared phases retain timer/IO scheduling overhead too.
These timings separate measured scopes, not every instruction inside Bend's
runtime. Phase medians need not sum to the E2E median.

Five samples give limited tail estimates. For example, one-core 4,096-character
full-batch work ranged from 905.98 to 1,072.82 ms. Host activity, WSL scheduling,
frequency and caches were not held constant. These raw observations provide a
reproducible method and a baseline on this host, not a universal ranking.
