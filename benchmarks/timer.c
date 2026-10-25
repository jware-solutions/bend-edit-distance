// Benchmark-only Bend 2.0.39 foreign-effect ABI; not part of the alignment API.
#include <time.h>
#include <inttypes.h>

static uint64_t bench_last;
static uint64_t bench_durations[8];

static uint64_t bench_now(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

Term start_run(Env e, Term* f, IoWork* w) {
  bench_last = bench_now();
  printf("ready,%" PRIu64 "\n", bench_last);
  fflush(stdout);
  // READY output is startup, outside all measured work phases.
  bench_last = bench_now();
  return term_pak(CID(Unit), 0);
}

Term mark_run(Env e, Term* f, IoWork* w) {
  uint64_t now = bench_now();
  if ((u32)f[0] >= 8) abort();
  bench_durations[(u32)f[0]] = now - bench_last;
  bench_last = now;
  return f[1];
}

Term finish_run(Env e, Term* f, IoWork* w) {
  for (unsigned i = 0; i < 8; ++i)
    printf("phase,%u,%" PRIu64 "\n", i, bench_durations[i]);
  printf("checksum,%" PRIu64 "\n", (uint64_t)f[0]);
  return term_pak(CID(Unit), 0);
}

Term release_run(Env e, Term* f, IoWork* w) {
  term_drop(e, f[0]);
  uint64_t now = bench_now();
  bench_durations[4] = now - bench_last;
  bench_last = now;
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) benchmark_effects(void) {
  io_eff(CID(start), start_run);
  io_eff(CID(mark), mark_run);
  io_eff(CID(release), release_run);
  io_eff(CID(finish), finish_run);
}
