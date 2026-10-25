// Validation-only Bend 2.0.39 ABI. Count only fully drained device bangs,
// plus CUDA batches AFTER successful synchronization (not logical rounds).
// CPU fallback cannot increment this counter. Keep production code untouched.
#include <inttypes.h>

static uint64_t gpu_measure_last, gpu_measure_work, gpu_measure_restore;
static uint64_t gpu_measure_in, gpu_measure_out;
static uint64_t gpu_measure_in_bytes, gpu_measure_out_bytes;
static int gpu_measure_prefetch;

#if BEND_CUDA
static void gpu_measure_check(CUresult result) {
  if (result != CUDA_SUCCESS) {
    const char* name = NULL;
    cuGetErrorName(result, &name);
    fprintf(stderr, "GPU measurement failed: %s\n", name ? name : "CUDA error");
    exit(3);
  }
}

static void gpu_measure_prefetch_range(CUdeviceptr pointer, size_t bytes, bool host) {
#if CUDA_VERSION >= 13000
  CUmemLocation location = {host ? CU_MEM_LOCATION_TYPE_HOST :
    CU_MEM_LOCATION_TYPE_DEVICE, host ? 0 : gpu_dev};
  gpu_measure_check(cuMemPrefetchAsync(pointer, bytes, location, 0, NULL));
#else
  gpu_measure_check(cuMemPrefetchAsync(pointer, bytes,
    host ? CU_DEVICE_CPU : gpu_dev, NULL));
#endif
}

static uint64_t gpu_measure_move(bool host, uint64_t* requested_bytes) {
  uint64_t started = bend_device_now();
  // Snapshot the allocator BEFORE enqueueing migrations: host reads must not
  // fault the header back while its device prefetch is in progress. Include
  // scheduler metadata, allocated arena pages (also freed pages) and occupied
  // allocator-bank entries; never migrate the whole reserved VRAM-sized heap.
  CUdeviceptr pointers[NCLS_ALL + 1];
  size_t lengths[NCLS_ALL + 1];
  unsigned count = 1;
  pointers[0] = (CUdeviceptr)(uintptr_t)CORPUS;
  lengths[0] = (HEAP_OFF + ((uint64_t)a32_load(a32_at(CORPUS, H_BUMP)) << PAGE_BITS)) * 8;
  if (lengths[0] > corpus_size) abort();
  *requested_bytes = lengths[0];
  for (unsigned c = 0; c < NCLS_ALL; ++c) {
    Bank* b = bank_at(CORPUS, c);
    uint32_t words = b->wr > b->top ? b->wr : b->top;
    if (b->rd > words) words = b->rd;
    if (!words) continue;
    if ((b->off + words) * 8 > corpus_size) abort();
    pointers[count] = (CUdeviceptr)(uintptr_t)(CORPUS + b->off);
    lengths[count] = (size_t)words * 8;
    *requested_bytes += lengths[count++];
  }
  for (unsigned i = 0; i < count; ++i)
    gpu_measure_prefetch_range(pointers[i], lengths[i], host);
  gpu_measure_check(cuCtxSynchronize());
  return bend_device_now() - started;
}
#endif

Term begin_run(Env e, Term* f, IoWork* w) {
  bend_completed_bangs = bend_scheduler_ns = 0;
  bend_sync_batches = bend_rounds_submitted = 0;
  gpu_measure_prefetch = term_aux(f[0]) == CID(True);
  if (gpu_measure_prefetch && !io_gpu) {
    fprintf(stderr, "Prefetch measurement requires a CUDA device\n");
    exit(3);
  }
#if BEND_CUDA
  if (io_gpu) {
    bend_device_memory();
    if (gpu_measure_prefetch) gpu_measure_in = gpu_measure_move(false, &gpu_measure_in_bytes);
    bend_device_memory();
  }
#endif
  gpu_measure_last = bend_device_now();
  return f[1];
}

Term end_run(Env e, Term* f, IoWork* w) {
  gpu_measure_work = bend_device_now() - gpu_measure_last;
#if BEND_CUDA
  if (io_gpu) {
    bend_device_memory();
    if (gpu_measure_prefetch) gpu_measure_out = gpu_measure_move(true, &gpu_measure_out_bytes);
  }
#endif
  gpu_measure_last = bend_device_now();
  return f[0];
}

Term finish_run(Env e, Term* f, IoWork* w) {
  gpu_measure_restore = bend_device_now() - gpu_measure_last;
  const char* backend = "cpu";
#if BEND_CUDA
  if (io_gpu) backend = "cuda";
#endif
  fprintf(stderr, "BEND_GPU_METRICS {\"schema\":2,\"backend\":\"%s\","
    "\"device_completed_bangs\":%" PRIu64 ",\"device_scheduler_ns\":%" PRIu64 ","
    "\"device_sync_batches\":%" PRIu64 ",\"device_rounds_submitted\":%" PRIu64 ","
    "\"work_ns\":%" PRIu64 ",\"restore_write_ns\":%" PRIu64 ","
    "\"prefetch_in_ns\":%" PRIu64 ",\"prefetch_out_ns\":%" PRIu64 ","
    "\"prefetch_in_requested_bytes\":%" PRIu64 ",\"prefetch_out_requested_bytes\":%" PRIu64 ","
    "\"managed_heap_bytes\":%" PRIu64 ",\"device_used_peak_sample_bytes\":",
    backend, bend_completed_bangs, bend_scheduler_ns, bend_sync_batches, bend_rounds_submitted, gpu_measure_work,
    gpu_measure_restore, gpu_measure_in, gpu_measure_out,
    gpu_measure_in_bytes, gpu_measure_out_bytes,
    io_gpu ? (uint64_t)corpus_size : 0);
  if (io_gpu) fprintf(stderr, "%" PRIu64, bend_device_used_peak);
  else fprintf(stderr, "null");
  fprintf(stderr, ",\"device_used_baseline_bytes\":");
  if (io_gpu) fprintf(stderr, "%" PRIu64, bend_device_used_baseline);
  else fprintf(stderr, "null");
  fprintf(stderr, "}\n");
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) gpu_measure_effects(void) {
  io_eff(CID(begin), begin_run);
  io_eff(CID(end), end_run);
  io_eff(CID(finish), finish_run);
}
