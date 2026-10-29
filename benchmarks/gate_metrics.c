// Benchmark-only ABI for the pinned Bend runtime. Allocation counters exist
// only in a separately compiled diagnostic executable.
#include <time.h>
#include <inttypes.h>

static uint64_t gate_last, gate_phases[10];
static uint64_t gate_now(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
  return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

Term ready_run(Env e, Term* f, IoWork* w) {
  fprintf(stderr, "BEND_GATE_READY %" PRIu64 "\n", gate_now());
  return term_pak(CID(Unit), 0);
}

Term reset_run(Env e, Term* f, IoWork* w) {
  memset(gate_phases, 0, sizeof(gate_phases));
#ifdef GATE_DEVICE_EVIDENCE
  bend_completed_bangs = bend_scheduler_ns = 0;
  bend_sync_batches = bend_rounds_submitted = 0;
#endif
#ifdef GATE_ALLOCATIONS
  atomic_store(&gate_allocations, 0);
#endif
  gate_last = gate_now();
  return term_pak(CID(Unit), 0);
}

Term mark_run(Env e, Term* f, IoWork* w) {
  uint64_t now = gate_now();
  if ((u32)f[0] >= 10) abort();
  gate_phases[(u32)f[0]] += now - gate_last;
  gate_last = now;
  return f[1];
}

Term finish_run(Env e, Term* f, IoWork* w) {
  fprintf(stderr, "BEND_GATE_METRICS {\"schema\":1,\"phases\":[");
  for (unsigned i = 0; i < 10; ++i)
    fprintf(stderr, "%s%" PRIu64, i ? "," : "", gate_phases[i]);
  fprintf(stderr, "]");
#ifdef GATE_DEVICE_EVIDENCE
  fprintf(stderr, ",\"device_completed_bangs\":%" PRIu64
    ",\"device_scheduler_ns\":%" PRIu64
    ",\"device_sync_batches\":%" PRIu64
    ",\"device_rounds_submitted\":%" PRIu64,
    bend_completed_bangs, bend_scheduler_ns,
    bend_sync_batches, bend_rounds_submitted);
#endif
#ifdef GATE_ALLOCATIONS
  fprintf(stderr, ",\"heap_alloc_calls\":%" PRIu64,
    (uint64_t)atomic_load(&gate_allocations));
#endif
  fprintf(stderr, "}\n");
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) gate_effects(void) {
  io_eff(CID(ready), ready_run);
  io_eff(CID(reset), reset_run);
  io_eff(CID(mark), mark_run);
  io_eff(CID(finish), finish_run);
}
