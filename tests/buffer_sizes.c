// Read physical buffer classes without consuming the returned array owner.
Term measured_run(Env e, Term *f, IoWork *w) {
    if (term_tag(f[0]) != TAG_BUF && term_tag(f[0]) != TAG_ARR) abort();
    return io_tup(e, f[0], 8ull << blk_span(f[0]));
}
static void __attribute__((constructor)) buffer_size_effects(void) {
    io_eff(CID(measured), measured_run);
}
