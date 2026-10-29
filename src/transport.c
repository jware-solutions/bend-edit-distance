// BED1 compatibility plus BED2 prepared/batch controls for the Bend worker.
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
    unsigned mode, task, format, version, operation;
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
    r->version = !memcmp(header, "BED1", 4) ? 1 : !memcmp(header, "BED2", 4) ? 2 : 0;
    if (!r->version) be_die("unsupported request version");
#ifdef BEND_EDLIB_ORACLE
    if (r->version != 1) be_die("unsupported request version");
#endif
    r->mode = header[4]; r->task = header[5]; r->format = header[6];
    r->operation = r->version == 2 ? header[7] : 0;
    r->threshold = be_u32(header + 8);
    r->query_length = be_u32(header + 12);
    r->target_length = be_u32(header + 16);
    r->pair_count = be_u32(header + 20);
    uint64_t expected = BE_REQUEST_SIZE;
    if (r->version == 1 || r->operation == 1)
        expected += (uint64_t)r->query_length + r->target_length + 2ull * r->pair_count;
    else if (r->operation == 2) expected += r->target_length;
    else if (r->operation == 5) expected += r->pair_count;
    else if (r->operation != 3 && r->operation != 4) expected = r->size;
    if (expected != r->size) be_die("inconsistent request lengths");
    size_t body_size = r->size - BE_REQUEST_SIZE;
    r->data = (unsigned char *)malloc(body_size ? body_size : 1);
    if (!r->data) be_die("request allocation failed");
    be_read_exact(r->data, body_size, 0);
    r->query = r->target = r->pairs = r->data;
    if (r->version == 1 || r->operation == 1) {
        r->target += r->query_length;
        r->pairs = r->target + r->target_length;
    }
    if (r->version == 1)
        return r->mode <= 2 && r->task <= 2 && r->format <= 1 && !header[7] ? 1 : 2;
    if (r->operation == 2 || r->operation == 5) {
        if (r->mode > 2 || r->task > 2 || r->format > 1 ||
            (r->operation == 2 && r->pair_count)) return 2;
    } else if (r->mode || r->task || r->format || r->threshold) return 2;
    switch (r->operation) {
        case 1: return !r->target_length && r->query_length <= 1048576 && r->pair_count <= 65536 ? 1 : 2;
        case 2: return 1;
        case 3: return !r->target_length && !r->pair_count ? 1 : 2;
        case 4: return !r->target_length && !r->pair_count && r->query_length <= 65536 ? 1 : 2;
        case 5: {
            if (r->target_length > 65536) return 2;
            size_t pos = 0;
            for (uint32_t i = 0; i < r->target_length; ++i) {
                if (body_size - pos < 4) be_die("truncated prepared batch");
                uint32_t n = be_u32(r->data + pos); pos += 4;
                if (n > body_size - pos) be_die("inconsistent prepared batch lengths");
                pos += n;
            }
            if (pos != body_size) be_die("trailing prepared batch data");
            return 1;
        }
        default: return 2;
    }
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


#ifdef CID(read_request)
// A Char occupies one raw U32 field in the pinned runtime. io_str decodes
// UTF-8 and cannot represent arbitrary wire bytes, including malformed UTF-8.
static Term be_byte_string(Env e, const unsigned char *bytes, uint32_t length) {
    Term string = term_pak(CID(SNil), 0);
    for (uint32_t i = length; i; --i)
        string = io_node(e, CID(SCon), bytes[i - 1], string);
    return string;
}

Term read_request_run(Env e, Term *f, IoWork *w) {
    BeRequest r;
    int state = be_read_request(&r);
    if (!state) return term_pak(CID(End), 0);
    if (state == 2) {
        free(r.data);
        if (r.version == 2) {
            return term_pak(CID(InvalidControl), r.operation);
        }
        return term_pak(CID(Invalid), 0);
    }
    if (r.version == 2) {
        Term result;
        if (r.operation == 1) {
            result = io_node(e, CID(PrepareRequest), be_byte_string(e, r.query, r.query_length),
                             io_list(e, (const char *)r.pairs, 2ull * r.pair_count));
        } else if (r.operation == 3 || r.operation == 4) {
            // The pinned compiler packs single U32 constructor fields inline.
            result = term_pak(r.operation == 3 ? CID(ReleaseRequest) : CID(BatchRequest), r.query_length);
        } else {
            Term targets;
            if (r.operation == 2) {
                targets = be_byte_string(e, r.target, r.target_length);
            } else {
                uint32_t *offsets = malloc(((size_t)r.target_length + 1) * sizeof(uint32_t));
                if (!offsets) be_die("batch offset allocation failed");
                size_t pos = 0;
                for (uint32_t i = 0; i < r.target_length; ++i) {
                    offsets[i] = (uint32_t)pos;
                    pos += 4ull + be_u32(r.data + pos);
                }
                targets = term_pak(CID(Nil), 0);
                for (uint32_t i = r.target_length; i; --i) {
                    size_t off = offsets[i - 1];
                    uint32_t length = be_u32(r.data + off);
                    Term target = io_node(e, CID(SizedTarget),
                        be_byte_string(e, r.data + off + 4, length), length);
                    targets = io_node(e, CID(Con), target, targets);
                }
                free(offsets);
            }
            // SizedTarget is flattened in PreparedRequest, but boxed as a
            // list element in PreparedBatchRequest (pinned emitted layout).
            u64 fields = heap_alloc(e, cls_fit(r.operation == 2 ? 7 : 6));
            e.mem[fields] = r.query_length; e.mem[fields + 1] = r.mode;
            e.mem[fields + 2] = r.task; e.mem[fields + 3] = r.threshold;
            e.mem[fields + 4] = r.format; e.mem[fields + 5] = targets;
            if (r.operation == 2) e.mem[fields + 6] = r.target_length;
            result = term_ctr(r.operation == 2 ? CID(PreparedRequest) : CID(PreparedBatchRequest), fields);
        }
        free(r.data);
        return result;
    }
    Term query = be_byte_string(e, r.query, r.query_length);
    Term target = be_byte_string(e, r.target, r.target_length);
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

#endif

#ifdef CID(write_response)
Term write_response_run(Env e, Term *f, IoWork *w) {
    u64 size;
    char *bytes = io_cbuf(e, f[0], &size, CID(Con));
    be_write_frame((const unsigned char *)bytes, size);
    free(bytes);
    return term_pak(CID(Unit), 0);
}

#endif

#ifdef CID(write_result_fields)
static uint32_t be_sequence_length(Env e, Term sequence, uint32_t con, uint32_t nil) {
    uint64_t length = 0;
    while (term_aux(sequence) == con) {
        uint64_t at = term_peek(e.mem, sequence);
        sequence = e.mem[at + 1];
        if (++length >= BE_NULL) be_die("result sequence exceeds length range");
    }
    if (term_aux(sequence) != nil) be_die("invalid result sequence");
    return (uint32_t)length;
}
static unsigned char *be_result_coordinates(Env e, Term sequence, unsigned char *out) {
    while (term_aux(sequence) == CID(Con)) {
        uint64_t at = term_peek(e.mem, sequence);
        be_put_u32(out, (uint32_t)e.mem[at]); out += 4;
        sequence = e.mem[at + 1];
    }
    return out;
}
static unsigned char *be_result_operations(Env e, Term sequence, unsigned char *out) {
    while (term_aux(sequence) == CID(Con)) {
        uint64_t at = term_peek(e.mem, sequence);
        uint32_t code = (uint32_t)e.mem[at];
        if (code > 3) be_die("invalid result operation");
        *out++ = (unsigned char)code;
        sequence = e.mem[at + 1];
    }
    return out;
}
static unsigned char *be_result_cigar(Env e, Term string, unsigned char *out) {
    while (term_aux(string) == CID(SCon)) {
        uint64_t at = term_peek(e.mem, string);
        *out++ = (unsigned char)e.mem[at];
        string = e.mem[at + 1];
    }
    return out;
}
Term write_result_fields_run(Env e, Term *f, IoWork *w) {
    // Each effect argument is one Term. Optional lists/strings use Base's
    // Some/None boxes; borrow their payloads until their owners are dropped.
    uint32_t present[3]; Term values[3];
    for (unsigned i = 0; i < 3; ++i) {
        Term option = f[3 + i];
        if (term_aux(option) == CID(None)) { present[i] = 0; values[i] = 0; }
        else if (term_aux(option) == CID(Some)) {
            present[i] = 1; values[i] = e.mem[term_peek(e.mem, option)];
        } else be_die("invalid optional result field");
    }
    uint32_t ends = be_sequence_length(e, f[2], CID(Con), CID(Nil));
    uint32_t starts = present[0] ? be_sequence_length(e, values[0], CID(Con), CID(Nil)) : BE_NULL;
    uint32_t operations = present[1] ? be_sequence_length(e, values[1], CID(Con), CID(Nil)) : BE_NULL;
    uint32_t cigar = present[2] ? be_sequence_length(e, values[2], CID(SCon), CID(SNil)) : BE_NULL;
    uint64_t size = BE_RESPONSE_SIZE + 4ull * ends + (present[0] ? 4ull * starts : 0)
        + (present[1] ? operations : 0) + (present[2] ? cigar : 0);
    if (size > INT_MAX) be_die("response exceeds protocol length range");
    unsigned char *buffer = malloc((size_t)size);
    if (!buffer) be_die("response allocation failed");
    memcpy(buffer, "BER1", 4);
    uint32_t fields[6] = {(u32)f[0], (u32)f[1], ends, starts, operations, cigar};
    for (unsigned i = 0; i < 6; ++i) be_put_u32(buffer + 4 + 4*i, fields[i]);
    unsigned char *out = be_result_coordinates(e, f[2], buffer + BE_RESPONSE_SIZE);
    if (present[0]) out = be_result_coordinates(e, values[0], out);
    if (present[1]) out = be_result_operations(e, values[1], out);
    if (present[2]) out = be_result_cigar(e, values[2], out);
    if ((uint64_t)(out - buffer) != size) be_die("inconsistent result lengths");
    be_write_frame(buffer, size); free(buffer);
    term_drop(e, f[2]);
    term_drop(e, f[3]);
    term_drop(e, f[4]);
    term_drop(e, f[5]);
    return term_pak(CID(Unit), 0);
}
#endif

static void __attribute__((constructor)) byte_transport_effects(void) {
#ifdef CID(write_result_fields)
    io_eff(CID(write_result_fields), write_result_fields_run);
#endif
#ifdef CID(read_request)
    io_eff(CID(read_request), read_request_run);
#endif
#ifdef CID(write_response)
    io_eff(CID(write_response), write_response_run);
#endif
}

#endif
