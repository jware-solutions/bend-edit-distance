// Benchmark-only ABI for the pinned Bend runtime. Allocation counters exist
// only in a separately compiled diagnostic executable.
#include <time.h>
#include <inttypes.h>
#include <sys/resource.h>

static uint64_t gate_last, gate_phases[10];
static uint32_t gate_owners;
#ifdef GATE_ALLOCATIONS
static uint64_t gate_live_start;
static uint64_t gate_phase_live[10], gate_phase_peak[10];
static uint64_t gate_phase_rss[10], gate_phase_hwm[10];
static void gate_memory(unsigned phase) {
  unsigned long pages, resident;
  FILE *file = fopen("/proc/self/statm", "r");
  if (!file || fscanf(file, "%lu %lu", &pages, &resident) != 2) abort();
  fclose(file);
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage)) abort();
  gate_phase_rss[phase] = resident * (uint64_t)sysconf(_SC_PAGESIZE) / 1024;
  gate_phase_hwm[phase] = usage.ru_maxrss;
}
#endif
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
  atomic_store(&gate_allocated_bytes, 0);
  gate_live_start = atomic_load(&gate_live_bytes);
  atomic_store(&gate_peak_bytes, gate_live_start);
  memset(gate_phase_live, 0, sizeof(gate_phase_live));
  memset(gate_phase_peak, 0, sizeof(gate_phase_peak));
  memset(gate_phase_rss, 0, sizeof(gate_phase_rss));
  memset(gate_phase_hwm, 0, sizeof(gate_phase_hwm));
#endif
#ifdef GATE_SCRATCH_TRACE
  gate_trace_reset();
#endif
  gate_last = gate_now();
  return term_pak(CID(Unit), 0);
}

Term mark_run(Env e, Term* f, IoWork* w) {
  uint64_t now = gate_now();
  if ((u32)f[0] >= 10) abort();
  gate_phases[(u32)f[0]] += now - gate_last;
  gate_last = now;
#ifdef GATE_SCRATCH_TRACE
  if ((u32)f[0] == 3) gate_trace_stop();
#endif
#ifdef GATE_ALLOCATIONS
  gate_phase_live[(u32)f[0]] = atomic_load(&gate_live_bytes);
  gate_phase_peak[(u32)f[0]] = atomic_load(&gate_peak_bytes);
  gate_memory((u32)f[0]);
#endif
  return f[1];
}

Term finish_run(Env e, Term* f, IoWork* w) {
  fprintf(stderr, "BEND_GATE_METRICS {\"schema\":1,\"phases\":[");
  for (unsigned i = 0; i < 10; ++i)
    fprintf(stderr, "%s%" PRIu64, i ? "," : "", gate_phases[i]);
  fprintf(stderr, "],\"effective_owners\":%u", gate_owners);
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
  fprintf(stderr, ",\"heap_allocated_bytes\":%" PRIu64
    ",\"heap_live_start_bytes\":%" PRIu64 ",\"heap_live_end_bytes\":%" PRIu64
    ",\"heap_peak_bytes\":%" PRIu64,
    (uint64_t)atomic_load(&gate_allocated_bytes), gate_live_start,
    (uint64_t)atomic_load(&gate_live_bytes), (uint64_t)atomic_load(&gate_peak_bytes));
  for (unsigned i = 0; i < 10; ++i)
    fprintf(stderr, ",\"heap_phase%u_live_bytes\":%" PRIu64
      ",\"heap_phase%u_peak_bytes\":%" PRIu64 ",\"phase%u_rss_kib\":%" PRIu64
      ",\"phase%u_hwm_kib\":%" PRIu64, i, gate_phase_live[i], i, gate_phase_peak[i],
      i, gate_phase_rss[i], i, gate_phase_hwm[i]);
#endif
#ifdef GATE_SCRATCH_TRACE
  fprintf(stderr, ",\"heap_scratch_peak_bytes\":%" PRIu64
    ",\"heap_temporary_allocated_bytes\":%" PRIu64
    ",\"heap_retained_new_bytes\":%" PRIu64
    ",\"heap_trace_events\":%" PRIu64,
    gate_scratch_peak, gate_temporary_bytes, gate_retained_bytes,
    (uint64_t)atomic_load(&gate_event_count));
#endif
  fprintf(stderr, "}\n");
  return term_pak(CID(Unit), 0);
}

Term owners_run(Env e, Term* f, IoWork* w) {
  gate_owners = (u32)f[1];
  return f[0];
}

Term dispose_run(Env e, Term* f, IoWork* w) {
  if ((u32)f[0] >= 10) abort();
  term_drop(e, f[1]);
  uint64_t now = gate_now();
  gate_phases[(u32)f[0]] += now - gate_last;
  gate_last = now;
#ifdef GATE_ALLOCATIONS
  gate_phase_live[(u32)f[0]] = atomic_load(&gate_live_bytes);
  gate_phase_peak[(u32)f[0]] = atomic_load(&gate_peak_bytes);
  gate_memory((u32)f[0]);
#endif
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) gate_effects(void) {
  io_eff(CID(ready), ready_run);
  io_eff(CID(reset), reset_run);
  io_eff(CID(mark), mark_run);
  io_eff(CID(finish), finish_run);
  io_eff(CID(owners), owners_run);
#if defined(CID(dispose))
  io_eff(CID(dispose), dispose_run);
#endif
}
