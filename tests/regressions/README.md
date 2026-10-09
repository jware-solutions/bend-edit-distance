# NW regression corpus

All distances here use unlimited global NW Levenshtein distance, unit edit
costs and ordinary case-sensitive equality on supported non-NUL ASCII inputs.

`nw.json` is a portable corpus of known edge cases seeded from the existing
test matrix and the case/word-boundary regressions added with it. These seeds
are not claimed to have been discovered by Hypothesis. Each case has a unique
`id`, `query`, `target` and independently checked expected `distance`.
`test_properties.py` replays them as explicit regressions and `@example`s.

Hypothesis saves failing examples and their smaller counterexamples under
ignored `build/hypothesis/`, with replay, generation and shrinking enabled.
Re-run the same failing test with `python run_tests.py --alignment -k NAME -v`.
After fixing a failure, copy its reduced input pair into `nw.json`, record the
correct distance and a descriptive id, and commit it with the fix. This retains
the regression across fresh checkouts and Hypothesis database/version changes.
For a triangle-only failure, also add the reduced triple as an `@example` on
the triangle property. Hypothesis prints a reproduction blob on failure too.

`upstream_nw.json` records its Edlib revision and source function for every
case. It migrates `test/runTests.cpp::test1` through `test10`, the NW portions
of `testEmptySequences`, and relevant pairs in `bindings/python/test.py` from
revision `0ddc23ea06abd95ab6227442acb4c27bd7607b68`.

Numeric symbols 0-9 are relabeled injectively to ASCII A-J because the CLI
cannot carry NUL. Declared array lengths and C++ implicit zero-filled tails
are preserved: notably `{1}` initializes one symbol to 1 and the rest to 0.
The 64-bit word-boundary case is retained and also adapted to a 32-bit Bend
word. No production behavior is changed by this migration. Expected distances
were calculated independently by scalar DP and checked against both Bend
implementations and the native Edlib oracle.

Excluded upstream tests exercise HW/SHW, custom equalities, full byte alphabets,
Unicode, locations, alignment paths or CIGAR. Those results are outside the
current Bend contract; their mode-specific expectations cannot be reused for NW.

The upstream cases are derived from Edlib, Copyright (c) 2014 Martin Šošić,
under the [MIT license](../../vendor/edlib/LICENSE), retained with the vendored source.
