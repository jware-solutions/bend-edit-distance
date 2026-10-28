// Opaque affine values are held only by the serialized worker's IO event loop.
// The pure library does not depend on this pinned-runtime transport cache.
#define PREPARED_LIMIT 32u
#define PREPARED_BYTES (64u * 1024u * 1024u)
static struct { uint32_t handle, bytes; Term value; } prepared_cache[PREPARED_LIMIT];
static uint32_t prepared_next = 1, prepared_count, prepared_bytes;

static unsigned prepared_slot(uint32_t handle) {
    for (unsigned i = 0; i < PREPARED_LIMIT; ++i)
        if (handle && prepared_cache[i].handle == handle) return i;
    return PREPARED_LIMIT;
}
static void prepared_bad_owner(void) {
    fprintf(stderr, "Prepared transport: invalid ownership transition\n");
    abort();
}
Term prepared_retain_run(Env e, Term *f, IoWork *w) {
    uint32_t bytes = (u32)f[1];
    if (!prepared_next || prepared_count >= PREPARED_LIMIT || bytes > PREPARED_BYTES - prepared_bytes) {
        term_drop(e, f[0]);
        return 0;
    }
    unsigned i = 0;
    while (prepared_cache[i].handle) ++i;
    uint32_t handle = prepared_next++;
    prepared_cache[i].handle = handle;
    prepared_cache[i].bytes = bytes;
    prepared_cache[i].value = f[0];
    ++prepared_count; prepared_bytes += bytes;
    return handle;
}
Term prepared_has_run(Env e, Term *f, IoWork *w) {
    return term_pak(prepared_slot((u32)f[0]) < PREPARED_LIMIT ? CID(True) : CID(False), 0);
}
Term prepared_take_run(Env e, Term *f, IoWork *w) {
    unsigned i = prepared_slot((u32)f[0]);
    if (i == PREPARED_LIMIT || !prepared_cache[i].value) prepared_bad_owner();
    Term value = prepared_cache[i].value;
    prepared_cache[i].value = 0;
    return value;
}
Term prepared_restore_run(Env e, Term *f, IoWork *w) {
    unsigned i = prepared_slot((u32)f[0]);
    if (i == PREPARED_LIMIT || prepared_cache[i].value) prepared_bad_owner();
    prepared_cache[i].value = f[1];
    return term_pak(CID(Unit), 0);
}
Term prepared_release_run(Env e, Term *f, IoWork *w) {
    unsigned i = prepared_slot((u32)f[0]);
    if (i == PREPARED_LIMIT) return term_pak(CID(False), 0);
    if (!prepared_cache[i].value) prepared_bad_owner();
    term_drop(e, prepared_cache[i].value);
    prepared_bytes -= prepared_cache[i].bytes; --prepared_count;
    memset(&prepared_cache[i], 0, sizeof(prepared_cache[i]));
    return term_pak(CID(True), 0);
}
Term prepared_cache_bytes_run(Env e, Term *f, IoWork *w) { return prepared_bytes; }
Term prepared_clear_run(Env e, Term *f, IoWork *w) {
    for (unsigned i = 0; i < PREPARED_LIMIT; ++i) {
        if (prepared_cache[i].handle) {
            if (!prepared_cache[i].value) prepared_bad_owner();
            term_drop(e, prepared_cache[i].value);
            memset(&prepared_cache[i], 0, sizeof(prepared_cache[i]));
        }
    }
    prepared_bytes = prepared_count = 0;
    return term_pak(CID(Unit), 0);
}
static void __attribute__((constructor)) prepared_effects(void) {
    io_eff(CID(retain), prepared_retain_run); io_eff(CID(has), prepared_has_run);
    io_eff(CID(take), prepared_take_run); io_eff(CID(restore), prepared_restore_run);
    io_eff(CID(release), prepared_release_run); io_eff(CID(clear), prepared_clear_run);
    io_eff(CID(cache_bytes), prepared_cache_bytes_run);
}
