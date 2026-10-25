// Version 1 byte protocol shared by the native Bend bridge and Edlib worker.
// All integers are little endian. See TRANSPORT.md for the wire contract.
#ifndef BEND_EDLIB_TRANSPORT_H
#define BEND_EDLIB_TRANSPORT_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define BE_NULL UINT32_MAX
#define BE_REQUEST_SIZE 24u
#define BE_RESPONSE_SIZE 28u

typedef struct {
    unsigned char *data;
    uint32_t size, query_length, target_length, pair_count, threshold;
    unsigned mode, task, format;
    const unsigned char *query, *target, *pairs;
} BeRequest;

static void be_die(const char *message) {
    fprintf(stderr, "Byte transport: %s\n", message);
    exit(2);
}

static uint32_t be_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void be_put_u32(unsigned char *p, uint32_t n) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(n >> (8 * i));
}

// EOF is clean only between frames. fread handles fragmented pipe writes.
static int be_read_exact(unsigned char *p, size_t n, int allow_eof) {
    size_t done = 0;
    while (done < n) {
        size_t got = fread(p + done, 1, n - done, stdin);
        if (!got) {
            if (ferror(stdin)) be_die("read failed");
            if (!done && allow_eof) return 0;
            be_die("truncated request");
        }
        done += got;
    }
    return 1;
}

// 0 = EOF, 1 = valid request, 2 = invalid configuration (recoverable).
// Framing/length/version errors are fatal: never guess the next boundary.
static int be_read_request(BeRequest *r) {
    unsigned char prefix[4], header[BE_REQUEST_SIZE];
    memset(r, 0, sizeof(*r));
    if (!be_read_exact(prefix, 4, 1)) return 0;
    r->size = be_u32(prefix);
    if (r->size < BE_REQUEST_SIZE || r->size > INT_MAX)
        be_die("invalid request frame length");
    be_read_exact(header, BE_REQUEST_SIZE, 0);
    if (memcmp(header, "BED1", 4)) be_die("unsupported request version");
    r->mode = header[4]; r->task = header[5]; r->format = header[6];
    r->threshold = be_u32(header + 8);
    r->query_length = be_u32(header + 12);
    r->target_length = be_u32(header + 16);
    r->pair_count = be_u32(header + 20);
    uint64_t expected = BE_REQUEST_SIZE + (uint64_t)r->query_length +
                        r->target_length + 2ull * r->pair_count;
    if (expected != r->size) be_die("inconsistent request lengths");
    size_t body_size = r->size - BE_REQUEST_SIZE;
    r->data = (unsigned char *)malloc(body_size ? body_size : 1);
    if (!r->data) be_die("request allocation failed");
    be_read_exact(r->data, body_size, 0);
    r->query = r->data;
    r->target = r->query + r->query_length;
    r->pairs = r->target + r->target_length;
    // Every i32 k is valid: all negative values request adaptive search.
    return r->mode <= 2 && r->task <= 2 && r->format <= 1 && !header[7] ? 1 : 2;
}

static void be_write_frame(const unsigned char *data, uint64_t size) {
    unsigned char prefix[4];
    if (size > INT_MAX) be_die("response exceeds protocol length range");
    be_put_u32(prefix, (uint32_t)size);
    if (fwrite(prefix, 1, 4, stdout) != 4 ||
        fwrite(data, 1, (size_t)size, stdout) != size || fflush(stdout))
        be_die("write failed");
}
#endif

#ifndef BEND_EDLIB_ORACLE
// Native effects for the pinned Bend 2.0.39 runtime. Core alignment stays Bend.
// The compiler splices this source into its generated C translation unit.


Term read_request_run(Env e, Term *f, IoWork *w) {
    BeRequest r;
    int state = be_read_request(&r);
    if (!state) return term_pak(CID(End), 0);
    if (state == 2) {
        free(r.data);
        return term_pak(CID(Invalid), 0);
    }
    Term query = io_list(e, (const char *)r.query, r.query_length);
    Term target = io_list(e, (const char *)r.target, r.target_length);
    Term pairs = io_list(e, (const char *)r.pairs, 2ull * r.pair_count);
    // Bend flattens constructor fields into consecutive heap words. This
    // layout is specific to the pinned compiler; no nested tuple boxes.
    u64 fields = heap_alloc(e, cls_fit(7));
    e.mem[fields + 0] = r.mode;
    e.mem[fields + 1] = r.task;
    e.mem[fields + 2] = r.threshold;
    e.mem[fields + 3] = r.format;
    e.mem[fields + 4] = query;
    e.mem[fields + 5] = target;
    e.mem[fields + 6] = pairs;
    free(r.data);
    return term_ctr(CID(Bytes), fields);
}

Term write_response_run(Env e, Term *f, IoWork *w) {
    u64 size;
    char *bytes = io_cbuf(e, f[0], &size, CID(Con));
    be_write_frame((const unsigned char *)bytes, size);
    free(bytes);
    return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) byte_transport_effects(void) {
    io_eff(CID(read_request), read_request_run);
    io_eff(CID(write_response), write_response_run);
}

#endif
