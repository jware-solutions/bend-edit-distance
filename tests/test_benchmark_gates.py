"""Fail-closed correctness, pairing, isolation and native phase boundaries."""

from dataclasses import replace
import json
from pathlib import Path
import subprocess
import time

import pytest

from alignment import AlignConfig, AlignResult, CigarFormat, Task
from bend_runtime import runtime_prefix
from benchmarks import gates
from benchmarks.gpu_runner import decode_batch
from benchmarks.runner import load_corpus, ROOT


def result(operations, cigar):
    return AlignResult.from_edlib({"status": 0, "edit_distance": 2, "end_locations": [1],
        "start_locations": [0], "alignment": operations, "cigar": cigar})


def test_complete_results_and_path_ties():
    workload = gates.Workload("tie", ((b"AC", b"CA", AlignConfig(task=Task.PATH)),))
    a, b = result([3, 3], "2X"), result([2, 0, 1], "1D1=1I")
    gates.validate([a], [b], workload)  # Both optimal, oracle tie policy may differ.
    with pytest.raises(RuntimeError, match="Complete baseline/candidate"):
        gates.validate([a], [b], workload, exact=True)
    with pytest.raises(RuntimeError, match="Path/CIGAR"):
        gates.validate([replace(a, cigar="2=")], [a], workload)
    with pytest.raises(RuntimeError, match="Ordered result"):
        gates.validate([replace(a, start_locations=None)], [a], workload)


def test_validation_cache_keys_inputs_configuration_and_keeps_oracle_independent():
    from alignment import EqualityPair, Mode, MaxDistance
    gates.cached_validation_distance.cache_clear()
    configurations = [AlignConfig(), AlignConfig(Mode.HW), AlignConfig(threshold=MaxDistance(0)),
        AlignConfig(equalities=(EqualityPair('A', 'N'), EqualityPair('N', 'C')))]
    for config in configurations:
        for q, t in ((b'A', b'C'), (b'A', b'N'), (b'AC', b'TAC'), (b'', b'A')):
            expected = gates.dp_distance(q, t, config)
            assert gates.validation_distance(q, t, config) == expected
            assert gates.validation_distance(q, t, config) == expected
    assert gates.cached_validation_distance.cache_info().hits == 16
    # Cached expected distances cannot bless an incorrect candidate answer.
    w = gates.Workload('bad', ((b'A', b'C', AlignConfig()),))
    bad = AlignResult.from_edlib(dict(status=0, edit_distance=0, end_locations=[0],
                                    start_locations=None, alignment=None, cigar=None))
    with pytest.raises(RuntimeError, match='Independent DP'):
        gates.validate([bad], [bad], w)
    before = gates.cached_validation_distance.cache_info()
    gates.validation_distance(b'A', b'C', AlignConfig(equalities=(EqualityPair('A', 'N'),) * 65))
    assert gates.cached_validation_distance.cache_info() == before


def test_session_replicas_keep_inputs_reuse_and_process_keys_distinct():
    jobs = ((b'A', b'C', AlignConfig()),)
    w = gates.Workload('case', jobs, batches=(jobs,), reuse_count=2, prepared_query=(b'A', AlignConfig()), seed=83)
    assert gates.replicate_sessions([w], 1) == [w]
    copies = gates.replicate_sessions([w], 3)
    assert [c.name for c in copies] == ['case/replica0', 'case/replica1', 'case/replica2']
    assert [c.replica for c in copies] == [0, 1, 2]
    assert all(c.payload == w.payload and c.batches == w.batches and c.reuse_count == 2
               and c.prepared_query == w.prepared_query and c.seed == w.seed for c in copies)
    for count in (0, 17):
        with pytest.raises(ValueError, match='Session replicas'):
            gates.replicate_sessions([w], count)


@pytest.mark.parametrize("qn,tn", [(0, 0), (0, 33), (33, 0), (31, 33), (33, 31),
                                    (65, 129), (129, 65), (4097, 1025)])
@pytest.mark.parametrize("name", ["one", "dna-random", "bytes-random", "equalities"])
def test_orientation_families_include_real_dimensions_and_fixed_query(qn, tn, name):
    from benchmarks.production_workloads import orientation_family
    a = orientation_family(name, qn, tn, 8, 831)
    assert a == orientation_family(name, qn, tn, 8, 831)
    q, config, batches = a
    assert len(q) == qn and len(batches) == 3
    assert all(len(batch) == 8 for batch in batches)
    assert all(query == q and len(target) == tn and c == config
               for batch in batches for query, target, c in batch)
    if qn and tn:
        assert len(set(batches)) == 3
    if name == "one" and qn and tn:
        assert set(q) <= set(b"ACGT")
        for batch in batches:
            for _, target, _ in batch:
                assert set(target) <= set(b"ACGT")
                assert sum(a != b for a, b in zip(q, target)) == 1


def test_orientation_families_fail_closed_on_length_changing_families():
    from benchmarks.production_workloads import orientation_family
    for name, qn, tn in [("indel", 65, 129), ("prep-dna", 65, 129), ("one", -1, 32)]:
        with pytest.raises(ValueError):
            orientation_family(name, qn, tn, 8, 3)


def test_corpus_preserved_and_additions_reproducible():
    corpus = load_corpus(ROOT / "benchmarks/corpus.json")
    a = gates.workloads(corpus, [1, 4], [1, 2, 8])
    b = gates.workloads(corpus, [1, 4], [1, 2, 8])
    assert [(w.name, w.payload) for w in a] == [(w.name, w.payload) for w in b]
    for case in corpus["cases"]:
        workload = next(w for w in a if w.name == case["name"] + "/1")
        assert workload.jobs == ((case["query"], case["target"], AlignConfig()),)
        assert workload.distances == (case["distance"],)
    repeated = next(w for w in a if w.name == "repeated/8")
    gates.validate_prepared(repeated.jobs)
    assert len({job[1] for job in repeated.jobs}) > 1
    with pytest.raises(ValueError, match="identical|one nonempty"):
        gates.validate_prepared((repeated.jobs[0], (b"other", b"target", AlignConfig())))
    configured = next(w for w in a if w.name == "configured")
    assert len({job[2].mode for job in configured.jobs}) == 3
    assert len({job[2].task for job in configured.jobs}) == 3
    assert len({job[2].cigar_format for job in configured.jobs}) == 2


def records():
    return [{"workload": "x", "mode": "batch", "lifetime": "fresh", "backend": "cpu",
        "threads": 1, "variant": name, "samples": [
            {"repetition": 0, "work_ns": values[0]}, {"repetition": 1, "work_ns": values[1]}]}
        for name, values in (("baseline", (100, 10000)), ("candidate", (120, 12000)))]


def test_paired_gate_enforces_regressions_and_missing_repetitions():
    pair = records()
    checks = gates.paired_gate(pair, 1.1)
    assert checks[0]["paired_ratios"] == [1.2, 1.2]
    assert checks[0]["passed"] is False
    assert gates.paired_gate(pair, 1.3)[0]["passed"] is True
    pair[1]["samples"][1]["repetition"] = 3
    with pytest.raises(RuntimeError, match="Unpaired"):
        gates.paired_gate(pair, 1.3)
    pair[1]["samples"].pop()
    with pytest.raises(RuntimeError, match="Missing"):
        gates.paired_gate(pair, 1.3)


def test_allocator_instrumentation_fails_on_unknown_runtime():
    with pytest.raises(RuntimeError, match="allocator changed"):
        gates.allocation_source("changed runtime")
    fixture = gates.ALLOC_ANCHOR + "\n    return h;\n  return heap_alloc_miss(e, cls);\n}\n" + gates.FREE_ANCHOR + "\n}"
    source = gates.allocation_source(fixture)
    assert "atomic_fetch_add_explicit" in source
    assert "atomic_fetch_sub_explicit" in source
    assert "8ull << cls" in source
    assert "atomic_compare_exchange_weak_explicit" in source
    assert "gate_record_event(h, cls, 1)" in source
    with pytest.raises(RuntimeError, match="allocator changed"):
        gates.allocation_source(fixture.replace("    return h;", "    return other;"))


def test_scratch_trace_tracks_lifetimes_before_retained_allocation(tmp_path):
    import os
    import shlex
    source = tmp_path / 'trace.c'
    binary = tmp_path / 'trace'
    source.write_text('#include <stdint.h>\n#include <stdbool.h>\n#include <stdatomic.h>\n'
        '#include <stdlib.h>\n#define GATE_SCRATCH_TRACE 1\n' + gates.allocation_trace_source() + '''
int main(void) {
  gate_trace_reset();
  gate_record_event(300, 2, 0); /* Storage predating this construction. */
  gate_record_event(100, 10, 1);
  gate_record_event(200, 10, 1);
  gate_record_event(100, 10, 0);
  gate_record_event(200, 10, 0);
  gate_record_event(100, 14, 1); /* Reused address, retained at boundary. */
  gate_trace_stop();
  return !(gate_scratch_peak == 16384 && gate_temporary_bytes == 16384
    && gate_retained_bytes == 131072);
}
''')
    gates.run_command([*shlex.split(os.environ.get('CC', 'clang-19')), '-std=c2x', source, '-o', binary])
    gates.run_command([binary])


def test_cuda_evidence_rejects_fallback():
    with pytest.raises(RuntimeError, match="fallback"):
        gates.check_device({"work_ns": 1}, True)
    gates.check_device(dict(work_ns=10, device_completed_bangs=1, device_scheduler_ns=8,
        device_sync_batches=2, device_rounds_submitted=3), True)


@pytest.mark.parametrize('release', ['2.0.39', '2.0.40'])
def test_reviewed_cuda_instrumentation_anchors(release):
    from benchmarks import gpu_runner as gpu
    cuda_pass = gpu.CUDA_PASS if release == '2.0.39' else gpu.CUDA_PASS_2040
    source = '\n'.join(['#define BANGS 1',
        '#if BEND_METAL || BEND_CUDA\n\nstatic void gpu_kernel(u32 pass, u32 at);',
        cuda_pass, gpu.GPU_RUN, gpu.CUDA_KERNEL, gpu.BRANCH,
        'static void cube_run(u64* H, bool gpu) {'])
    measured = gpu.instrument(source)
    assert measured.count('bend_sync_batches += 1;') == 1
    assert measured.count('bend_completed_bangs += 1;') == 1
    assert 'root_done(H)' in measured
    if release == '2.0.40':
        assert 'cuMemcpyHtoD(gpu_front, &H[H_FRONT], 8)' in measured
    with pytest.raises(RuntimeError, match='runtime changed'):
        gpu.instrument(source.replace('cuCtxSynchronize()', 'unreviewed_sync()'))
    with pytest.raises(RuntimeError, match='runtime changed'):
        gpu.instrument(source + cuda_pass)


@pytest.fixture(scope="module")
def gate_binary(bend_tool, tmp_path_factory):
    import os
    import shlex
    directory = tmp_path_factory.mktemp("gate-native")
    binary, metadata = gates.build(ROOT, directory / "timed", bend_tool,
        shlex.split(os.environ.get("CC", "clang-19")), ["-std=c2x", "-O3", "-pthread"])
    return binary, metadata


def exchange(binary, workload, mode, rounds=1):
    argv = [binary, *runtime_prefix(threads=1, gpu="off"), mode, len(workload.jobs), rounds]
    started = time.monotonic_ns()
    worker = gates.Worker(argv, 60)
    values, samples = [], []
    try:
        startup = worker.ready(started)
        for _ in range(rounds):
            value, sample = worker.request(workload.payload, len(workload.jobs))
            values.append(value)
            samples.append(sample)
        worker.finish()
    finally:
        worker.close()
    return values, samples, startup


@pytest.mark.parametrize("name", ["configured", "reconstruction", "repeated/4", "equalities/1"])
def test_native_stages_and_persistent_results(gate_binary, cpp_binary, name):
    binary, _ = gate_binary
    workload = next(w for w in gates.workloads(load_corpus(ROOT / "benchmarks/corpus.json"), [1], [4]) if w.name == name)
    oracle = subprocess.run([str(cpp_binary), "--worker"], input=workload.payload,
                            capture_output=True, timeout=60, check=True)
    expected = decode_batch(oracle.stdout, len(workload.jobs))
    batch, samples, startup = exchange(binary, workload, "batch", rounds=2)
    for value in batch:
        gates.validate(value, expected, workload)
        assert value == batch[0]
    assert startup["startup_ns"] > 0
    assert samples[0]["planning_ns"] > 0 and samples[0]["ordering_ns"] > 0
    for sample in samples:
        assert "heap_alloc_calls" not in sample
    phases, samples, _ = exchange(binary, workload, "phases")
    assert phases[0] == batch[0]
    assert samples[0]["profile_ns"] > 0 and samples[0]["search_ns"] > 0
    if name == "reconstruction":
        assert samples[0]["reconstruction_ns"] > 0 and samples[0]["result_ns"] > 0
    if workload.reuse:
        prepared, reused_samples, _ = exchange(binary, workload, "prepared")
        assert prepared[0] == batch[0]
        sample = reused_samples[0]
        assert sample["profile_ns"] > 0
        assert sample["total_cost_ns"] == sum(sample[key] for key in gates.PHASES if key != "serialization_ns")
        assert sample["amortized_total_ns"] == sample["total_cost_ns"] / len(workload.jobs)


def test_gate_cli_records_pairing_and_temp_artifacts(gate_binary, tmp_path, monkeypatch):
    binary, metadata = gate_binary
    flags = []
    def build(*args, **kwargs):
        flags.append(args[4])
        return binary, metadata
    monkeypatch.setattr(gates, "build", build)
    output = tmp_path / "results"
    code = gates.main(["--threads", "1", "--batch-sizes", "1", "--reuse-counts", "1",
        "--workload", "example/1", "--warmups", "1", "--repeats", "2",
        "--max-regression", "100000", "--output", str(output),
        "--baseline-cflags=-std=c2x -O2 -pthread",
        "--candidate-cflags=-std=c2x -O3 -pthread"])
    assert code == 0
    document = json.loads((output / "results.json").read_text())
    assert document["status"] == "passed"
    assert flags == [["-std=c2x", "-O2", "-pthread"], ["-std=c2x", "-O3", "-pthread"]]
    assert len(document["records"]) == 8
    for record in document["records"]:
        assert [s["repetition"] for s in record["samples"]] == [0, 1]
        assert [s["order"] for s in record["samples"]] == ([1, 0] if record["variant"] == "baseline" else [0, 1])
        assert record["affinity_cpus"] == document["environment"]["selected_cpus"][:1]
        for sample in record["samples"]:
            assert "heap_alloc_calls" not in sample
    assert {p.suffix for p in output.iterdir()} == {".json", ".csv"}
    assert not Path(metadata["commands"][1][-1]).is_relative_to(ROOT)


def test_missing_required_metrics_and_coverage_fail_closed():
    pair = records()
    with pytest.raises(RuntimeError, match="required metric"):
        gates.paired_gate(pair, 1.1, ["absent_ns"])
    with pytest.raises(RuntimeError, match="coverage"):
        gates.paired_gate([], 1.1)
    with pytest.raises(RuntimeError, match="Missing baseline"):
        gates.paired_gate(pair[:1], 1.1)
    with pytest.raises(RuntimeError, match="Duplicate"):
        gates.paired_gate(pair + pair[:1], 1.1)


def test_production_families_dna_and_batch_identities():
    from benchmarks.production_workloads import family, FAMILIES, PREPARATION_FAMILIES
    for name in set(FAMILIES) - set(PREPARATION_FAMILIES):
        q, config, batches = family(name, 129, 8, 42)
        assert (q, config, batches) == family(name, 129, 8, 42)
        assert len(batches) == 3
        if name not in ("identical", "bytes-identical"):
            assert len(set(batches)) == 3
        else:
            assert all(t == q for batch in batches for _, t, _ in batch)
        if not name.startswith("bytes-"):
            assert set(q) <= set(b"ACGT")
            for batch in batches:
                assert all(set(t) <= set(b"ACGTN" if name == "equalities" else b"ACGT") for _, t, _ in batch)
    for count in (0, 1, 2):
        _, _, batches = family("one", 129, count, 42)
        assert all(len(batch) == count for batch in batches)
        if count:
            assert len(set(batches)) == 3
            for batch in batches:
                for q, t, _ in batch:
                    assert sum(a != b for a, b in zip(q, t)) == 1


def test_production_applicability_and_fallback_detection():
    from benchmarks.production_gate import applicable, route_evidence
    from alignment import MaxDistance
    zero = gates.Workload("zero", (), prepared_query=(b"ACGT", AlignConfig()))
    assert applicable("string-batch", zero) is None
    assert applicable("owned-worker-batch", zero) is None
    assert applicable("string-single", zero)
    finite = gates.Workload("finite", ((b"A", b"T", AlignConfig(threshold=MaxDistance(1))),))
    assert applicable("owned-worker-single", finite)
    assert applicable("compatible-worker-single", finite) is None
    assert route_evidence("owned-worker-single", [1, 8, 6], [])['actual_route'] == '6'
    with pytest.raises(RuntimeError, match="fallback"):
        route_evidence("owned-worker-single", [1, 8, 6, 2], [])
    with pytest.raises(RuntimeError, match="rejected"):
        route_evidence("owned-worker-batch", [7], [{"operation": 7, "status": 1}])


def test_native_zero_batch_metrics(gate_binary):
    values, samples, _ = exchange(gate_binary[0], gates.Workload("zero", ()), "batch")
    assert values == [[]]
    assert "amortized_total_ns" not in samples[0]


@pytest.fixture(scope="module")
def production_binaries(bend_tool, tmp_path_factory):
    import os
    import shlex
    directory = tmp_path_factory.mktemp("production-gate")
    cc = shlex.split(os.environ.get("CC", "clang-19"))
    from benchmarks.production_gate import build_references
    refs, _ = build_references(directory / "references", shlex.split(os.environ.get("CXX", "g++")), "-O3", u32=True)
    api, _ = gates.build(ROOT, directory / "api", bend_tool, cc,
        ["-std=c2x", "-O3", "-pthread"], entry_name="benchmarks/production_api.bend")
    compatible, _ = gates.build(ROOT, directory / "compatible", bend_tool, cc,
        ["-std=c2x", "-O3", "-pthread"], entry_name="benchmarks/compatible_worker.bend")
    return api, compatible, refs


@pytest.mark.parametrize("mode", ["string-single", "string-batch", "string-serial-batch"])
def test_production_string_complete_parity(production_binaries, cpp_binary, mode):
    from benchmarks.production_gate import Native
    from alignment import Mode, EqualityPair, MaxDistance
    from transport import AlignmentWorker
    api, _, _ = production_binaries
    query = bytes(range(256)) + b"AN"
    with AlignmentWorker([cpp_binary, "--worker"]) as oracle:
        for alignment_mode in Mode:
            for task in Task:
                for format in CigarFormat:
                    config = AlignConfig(alignment_mode, task, MaxDistance(300),
                        (EqualityPair(0, 255), EqualityPair('A', 'N'), EqualityPair('N', 'C')), format)
                    for targets in ([query], [b"", b"A", query, query[::-1], query]) if mode != "string-single" else ([query], [b""], [b"A"]):
                        jobs = tuple((query, t, config) for t in targets)
                        w = gates.Workload("api", jobs)
                        session = Native(api, mode, w, 2, 2, 60, 2)
                        try:
                            expected = [oracle.align(*j) for j in jobs]
                            for _ in range(2):
                                actual, metrics = session.call(jobs)
                                gates.validate(actual, expected, w)
                            assert session.setup['effective_owners'] == (2 if mode == 'string-batch' else 1)
                            session.worker.finish()
                        finally:
                            session.close()


def test_cached_profile_parity_and_optional_rejection(production_binaries, cpp_binary):
    from benchmarks.production_gate import ObservedWorker
    from transport import AlignmentWorker
    from alignment import MaxDistance, EqualityPair
    _, compatible, refs = production_binaries
    with AlignmentWorker([cpp_binary, '--worker']) as oracle:
        for name in ('public', 'cached', 'public-u32-diagnostic', 'cached-u32-diagnostic'):
            with ObservedWorker([refs[name], '2']) as control:
                for n in (*range(65), 95, 96, 97, 127, 128, 129, 257):
                    query = bytes(range(256))[:n] if n <= 256 else bytes(range(256)) + b'A'
                    pairs = (EqualityPair(0, 255), EqualityPair(255, 127), EqualityPair(255, 0), EqualityPair(0, 255))
                    with control.prepare(query, pairs) as prepared:
                        optimum = oracle.align(query, query[::-1], AlignConfig(equalities=pairs)).edit_distance
                        for k in sorted({-1, 0, max(0, optimum - 1), optimum, optimum + 1, n, n + 1}):
                            config = AlignConfig(equalities=pairs) if k < 0 else AlignConfig(threshold=MaxDistance(k), equalities=pairs)
                            targets = [query, b'', query[::-1], b'\x00\xff', query + b'A']
                            expected = [oracle.align(query, t, config) for t in targets]
                            actual = prepared.align_batch(targets, config)
                            gates.validate(actual, expected, gates.Workload('reference', tuple((query,t,config) for t in targets)))
                            assert prepared.align_batch([], config) == []
        with ObservedWorker([compatible, *runtime_prefix(threads=1), '--worker']) as old:
            with old.prepare(b'ACGT' * 8) as prepared:
                for _ in range(2):
                    assert prepared.align(b'ACGT' * 8).edit_distance == 0
                    assert len(prepared.align_batch([b'', b'A', b'ACGT' * 8])) == 3
                assert old.operations.count(6) == old.operations.count(7) == 1
                assert old.operations.count(2) == old.operations.count(5) == 2
                assert any(c['operation'] == 6 and c['status'] == 1 for c in old.controls)
                assert any(c['operation'] == 7 and c['status'] == 1 for c in old.controls)


def test_u32_diagnostic_requires_production_boundary():
    with pytest.raises(SystemExit):
        gates.main(['--edlib-u32'])
    with pytest.raises(SystemExit):
        gates.main(['--edlib-u32', '--family', 'dna-random:129'], device=True)


def test_owned_dispatch_limits_and_compatible_continuation(bend_binary, cpp_binary):
    from benchmarks.production_gate import ObservedWorker, route_evidence
    from transport import AlignmentWorker
    from alignment import Mode, MaxDistance
    with ObservedWorker([bend_binary, *runtime_prefix(threads=1), '--worker', '--shards', '1']) as w, AlignmentWorker([cpp_binary, '--worker']) as oracle:
        for n in (32, 129, 65536, 65537):
            query = (b'ACGT' * ((n + 3) // 4))[:n]
            with w.prepare(query) as owner:
                w.operations.clear(); w.controls.clear()
                actual = owner.align(b'')
                assert actual == oracle.align(query, b'')
                if n <= 65536:
                    route_evidence('owned-worker-single', w.operations, w.controls)
                else:
                    assert 2 in w.operations and 6 not in w.operations
                for mode in Mode:
                    for task in Task:
                        config = AlignConfig(mode=mode, task=task, threshold=MaxDistance(0))
                        before = len(w.operations)
                        actual = owner.align_batch([b'', b'A', b'A'], config)
                        expected = [oracle.align(query, t, config) for t in (b'', b'A', b'A')]
                        gates.validate(actual, expected, gates.Workload('fallback', tuple((query,t,config) for t in (b'', b'A', b'A'))))
                        assert 5 in w.operations[before:] and 7 not in w.operations[before:]
                assert owner.align(query).edit_distance == 0


def test_production_allocation_stages_are_separate(bend_tool, cpp_binary, tmp_path):
    import os
    import shlex
    from benchmarks.production_gate import Native
    binary, metadata = gates.build(ROOT, tmp_path / 'diagnostic', bend_tool,
        shlex.split(os.environ.get('CC', 'clang-19')), ['-std=c2x', '-O3', '-pthread'],
        entry_name='benchmarks/production_diagnostics.bend', allocations=True)
    assert metadata['allocations'] is True
    w = gates.Workload('stages', ((b'ACGT' * 40, b'ACGT' * 39 + b'ACGA', AlignConfig()),) * 2)
    session = Native(binary, 'string-diagnostic', w, 2, 2, 60, 1)
    try:
        values, metrics = session.call(w.jobs)
        assert len(values) == 2 and all(r.edit_distance == 1 for r in values)
        assert metrics['heap_alloc_calls'] > 0
        assert metrics['effective_owners'] == metrics['planned_active_leaves'] == 2
        assert all(metrics[k] > 0 for k in ('planning_ns', 'work_ns', 'ordering_ns'))
        session.worker.finish()
    finally:
        session.close()
    search = Native(binary, 'search-diagnostic', w, 1, 1, 60, 1)
    try:
        values, metrics = search.call(w.jobs)
        assert all(r.edit_distance == 1 for r in values)
        assert metrics['search_ns'] > 0 and metrics['result_ns'] > 0
        assert metrics['search_counts_exact'] == 1
        assert metrics['searched_columns'] == 320 and metrics['search_attempts'] == 2
        assert metrics['searched_blocks'] > 0
        search.worker.finish()
    finally:
        search.close()
    for count in (0, 1, 3, 5):
        jobs = w.jobs[:1] * count
        probe = Native(binary, 'string-diagnostic', replace(w, jobs=jobs), 1, 4, 60, 1)
        try:
            values, metrics = probe.call(jobs)
            assert len(values) == count
            assert metrics['effective_owners'] == 4
            assert metrics['planned_active_leaves'] == min(4, max(1, count))
            probe.worker.finish()
        finally:
            probe.close()
    from alignment import MaxDistance
    from transport import AlignmentWorker
    with AlignmentWorker([cpp_binary, '--worker']) as oracle:
        for count in (0, 1, 8, 128):
            query = w.jobs[0][0]
            targets = [query, b'', query[:-1] + b'Z', query[::-1]]
            jobs = tuple((query, targets[i % 4], AlignConfig()) for i in range(count))
            owned = Native(binary, 'owned-diagnostic', replace(w, jobs=jobs), 1, 4, 60, 2)
            try:
                for batch in (jobs, jobs[::-1]):
                    actual, metrics = owned.call(batch)
                    gates.validate(actual, [oracle.align(*job) for job in batch], replace(w, jobs=batch))
                    work = sum(len(job[1]) for job in batch) * 5 + count * 32
                    assert metrics['effective_owners'] == 4
                    assert metrics['planned_active_leaves'] == (4 if work >= 65536 else 1)
                    assert metrics['locations_ns'] > 0  # estimator/active-owner selection
                owned.worker.finish()
            finally:
                owned.close()
        for length, count, columns in ((96, 2, 21824), (97, 2, 8176),
                                       (128, 2, 8176), (129, 3, 13088)):
            query = b'A' * length
            for offset in (-1, 0, 1):
                total = columns + offset
                jobs = tuple((query, b'C' * (total // count + (i < total % count)), AlignConfig())
                             for i in range(count))
                exact = Native(binary, 'owned-diagnostic', replace(w, jobs=jobs), 2, 4, 60, 1)
                try:
                    actual, metrics = exact.call(jobs)
                    gates.validate(actual, [oracle.align(*job) for job in jobs], replace(w, jobs=jobs))
                    assert metrics['planned_active_leaves'] == (1 if offset < 0 else count)
                    exact.worker.finish()
                finally:
                    exact.close()
        for format in CigarFormat:
            for limit in (-1, 0, 1, 2):
                config = AlignConfig(task=Task.PATH, cigar_format=format) if limit < 0 else AlignConfig(
                    task=Task.PATH, threshold=MaxDistance(limit), cigar_format=format)
                jobs = tuple((q, t, config) for q, t, _ in w.jobs)
                path_workload = gates.Workload('path-stages', jobs)
                expected = [oracle.align(*job) for job in jobs]
                session = Native(binary, 'search-diagnostic', path_workload, 1, 1, 60, 2)
                try:
                    for _ in range(2):
                        actual, metrics = session.call(jobs)
                        gates.validate(actual, expected, path_workload)
                        assert metrics['search_ns'] > 0 and metrics['result_ns'] > 0
                        assert (metrics['reconstruction_ns'] == 0) == (limit == 0)
                    session.worker.finish()
                finally:
                    session.close()


def test_configuration_option_and_empty_metric_rejection():
    args = gates.parser(False).parse_args(['--family', 'one:129', '--configuration', 'HW:PATH:2:STANDARD'])
    assert args.configuration == ['HW:PATH:2:STANDARD']
    pair = records()
    for record in pair:
        for sample in record['samples']:
            sample['work_ns'] = 0
    with pytest.raises(RuntimeError, match='No nonzero'):
        gates.paired_gate(pair, 1.1)


@pytest.mark.parametrize('fresh', [False, True])
def test_production_cli_end_to_end(production_binaries, bend_binary, tmp_path, monkeypatch, fresh):
    from benchmarks import production_gate
    import shutil
    api, _, refs = production_binaries
    compilers = {v: tmp_path / v / 'bin/bend' for v in ('baseline', 'candidate')}
    for path in compilers.values():
        path.parent.mkdir(parents=True)
        shutil.copyfile(shutil.which('bend'), path)
        path.chmod(0o755)
        shutil.copytree(Path(shutil.which('bend')).resolve().parent.parent / 'bend2', path.parent.parent / 'bend2')
    routed = []
    def build(root, directory, bend, cc, flags, **kwargs):
        variant = directory.parent.name
        assert bend == compilers[variant]
        routed.append((variant, kwargs['entry_name'], directory))
        binary = bend_binary if kwargs['entry_name'] == 'worker.bend' else api
        return binary, {'allocations': False, 'commands': [], 'binary_sha256': gates.digest(binary.read_bytes())}
    monkeypatch.setattr(gates, 'build', build)
    monkeypatch.setattr(production_gate, 'build_references', lambda *a: (refs, {}))
    output = tmp_path / 'production-results'
    code = gates.main(['--mode', 'owned-worker-batch', '--mode', 'ordinary-worker-batch', '--mode', 'string-batch',
        '--family', 'one:129', '--batch-sizes', '0', '1', '--reuse-counts', '1', '--threads', '1',
        '--baseline-bend', str(compilers['baseline']), '--candidate-bend', str(compilers['candidate']),
        '--warmups', '1', '--repeats', '2', '--max-regression', '100000', '--output', str(output),
        *(['--fresh-prepared'] if fresh else [])])
    assert code == 0
    document = json.loads((output / 'results.json').read_text())
    assert document['status'] == 'passed' and len(document['coverage']) == 6
    assert {(v, entry) for v, entry, _ in routed} == {
        (v, entry) for v in compilers for entry in ('benchmarks/production_api.bend', 'worker.bend')}
    assert len({directory for _, _, directory in routed}) == len(routed)
    assert {v: info['path'] for v, info in document['provenance']['bend_compilers'].items()} == {
        v: str(path) for v, path in compilers.items()}
    assert len(document['records']) == 12
    for record in document['records']:
        if record['mode'] == 'string-batch':
            assert record['process_usage']['process_peak_rss_kib'] > 0
            assert record['setup']['native_startup_ns'] > 0
            assert record['setup']['memory_after_setup']['os_threads'] >= 1
        if record['mode'].startswith('owned'):
            assert record['execution']['actual_route'] == '7'
            assert record['effective_owners'] == 1
        if record['batch_size'] == 0:
            assert all('amortized_per_target_ns' not in s for s in record['samples'])
        if record['mode'].endswith('worker-batch') and not record['mode'].startswith('ordinary'):
            if fresh:
                assert all(s['prepared_group_budget_bytes'] > 0 and s['retained_budget_bytes'] == 0
                    and s['lifecycle_ns'] == s['total_with_prepare_ns'] + s['release_service_ns']
                    for s in record['samples'])
            else:
                assert record['setup']['after_release_retained_budget_bytes'] == 0
    assert (output / 'summary.csv').exists()
    assert not (output / 'REPORT.md').exists()
    assert not (output / 'summary.md').exists()


def test_every_production_build_kind_routes_its_compiler(tmp_path, monkeypatch):
    from benchmarks import production_gate as production
    args = gates.parser(False).parse_args(['--mode', 'batch', '--mode', 'string-batch',
        '--mode', 'owned-worker-batch', '--allocations'])
    bends = {v: tmp_path / (v + '-bend') for v in ('baseline', 'candidate')}
    identities = {v: {'path': str(p), 'version': 'bend 2.0.' + str(39 + i)}
        for i, (v, p) in enumerate(bends.items())}
    document = {'provenance': {'driver_sha256': {}, 'bend_compilers': identities},
                'phase_semantics': {}, 'records': []}
    calls = []
    def build(root, directory, bend, cc, flags, **kwargs):
        variant, kind = directory.parent.name, directory.name
        assert bend == bends[variant]
        assert kwargs['compiler_identity'] == identities[variant]
        assert kwargs['allocations'] == (kind == 'diagnostic')
        calls.append((variant, kind, directory))
        return directory / 'unused', {}
    class BeforeMeasurements(Exception):
        pass
    def stop(*args, **kwargs):
        raise BeforeMeasurements
    monkeypatch.setattr(gates, 'build', build)
    monkeypatch.setattr(production, 'build_references', lambda *a, **k: ({'oracle': 'unused'}, {}))
    monkeypatch.setattr(production, 'AlignmentWorker', stop)
    with pytest.raises(BeforeMeasurements):
        production.run(args, document, [], [0], bends, ['clang-19'], ['clang++-19'], tmp_path)
    assert {(v, k) for v, k, _ in calls} == {
        (v, k) for v in bends for k in ('api', 'core', 'diagnostic', 'worker')}
    assert len({d for _, _, d in calls}) == 8


def test_native_empty_round_waits_for_request(gate_binary):
    import selectors
    binary, _ = gate_binary
    worker = gates.Worker([binary, *runtime_prefix(threads=1), 'batch', '0', '2'], 10)
    try:
        # Empty batches are real round trips, never eager startup output.
        worker.ready(time.monotonic_ns() - 10_000_000_000)
        for _ in range(2):
            with selectors.DefaultSelector() as selector:
                selector.register(worker.process.stderr, selectors.EVENT_READ)
                assert not selector.select(.05)
            values, metrics = worker.request(b'', 0)
            assert values == [] and 'amortized_total_ns' not in metrics
        worker.finish()
    finally:
        worker.close()


@pytest.mark.parametrize("seed", [42, 4862, 9081])
def test_certificate_placements_have_distinct_batches_and_independent_distances(seed):
    from benchmarks.production_workloads import family, CERTIFICATE_FAMILIES
    from tests.test_small_paths import distance_dp
    for name in CERTIFICATE_FAMILIES:
        query, config, batches = family(name, 129, 1, seed)
        assert len(set(batches)) == 3
        scan = list(range(32)) + list(range(128, 31, -1))
        for batch in batches:
            _, target, _ = batch[0]
            assert set(target) <= set(b"ACGT")
            mismatches = [i for i, (a, b) in enumerate(zip(query, target)) if a != b]
            optimum = distance_dp(query, target, config.equalities)
            if name.startswith("two-") or name == "short-shift":
                assert optimum == 2
            if name.startswith("three-"):
                assert len(mismatches) == 3
                third = max(scan.index(p) for p in mismatches)
                assert third == {"three-early": 2, "three-middle": 96, "three-late": 128, "three-tail": 128}[name]
                assert 2 <= optimum <= 3


def test_preparation_families_are_direct_and_reproducible():
    from benchmarks.production_workloads import PREPARATION_FAMILIES, family
    for name in PREPARATION_FAMILIES:
        a = family(name, 257, 3, 932)
        assert a == family(name, 257, 3, 932)
        query, config, batches = a
        assert len(batches) == 3 and all(len(b) == 3 for b in batches)
        assert len(config.equalities) <= 65536
        for batch in batches:
            for q, target, c in batch:
                assert q == query and c == config and target != q
    query, config, _ = family("prep-irrelevant", 4096, 1, 1)
    assert set(query) == {65}
    assert all(p.first not in set(query) and p.second not in set(query) for p in config.equalities)


def test_fresh_preparation_cycle_boundaries(production_binaries, cpp_binary, bend_tool):
    from benchmarks.production_gate import Native
    from benchmarks.production_workloads import family
    from transport import AlignmentWorker
    api, _, _ = production_binaries
    q, config, batches = family("prep-sparse", 129, 4, 133)
    w = gates.Workload("prepare", batches[0], batches=batches, prepared_query=(q, config))
    from benchmarks import gates as G
    binary, _ = G.build(ROOT, api.parent.parent / "preparation", bend_tool,
        [str(ROOT / "scripts/cc")], ["-std=c2x", "-O3", "-pthread"], entry_name="benchmarks/production_preparation.bend")
    session = Native(binary, "prepare-batch", w, 2, 2, 60, 3)
    try:
        with AlignmentWorker([cpp_binary, '--worker']) as oracle:
            for jobs in batches:
                actual, metrics = session.call(jobs)
                gates.validate(actual, [oracle.align(*job) for job in jobs], replace(w, jobs=jobs))
                assert all(metrics[k] > 0 for k in ('profile_ns', 'prepare_ns', 'work_ns', 'search_ns'))
                assert metrics['effective_owners'] == 2
        session.worker.finish()
    finally:
        session.close()


def test_fresh_service_reuse_groups_release_and_readmit(bend_binary, cpp_binary):
    from benchmarks.production_gate import Service
    from transport import AlignmentWorker
    query = b"AN" * 65
    from alignment import EqualityPair
    config = AlignConfig(equalities=(EqualityPair('A', 'N'), EqualityPair('N', 'C')))
    w = gates.Workload("lifecycle", ((query, query, config),))
    session = Service(bend_binary, "owned-worker-single", w, 1, 1, 60, fresh=True)
    handles = []
    try:
        with AlignmentWorker([cpp_binary, '--worker']) as oracle:
            for targets in ((query, query[1:] + b'T'), (b'T' * len(query), query)):
                assert session.begin_group() > 0
                handles.append(session.owner.handle)
                assert session.worker.retained_entries == 1
                for target in targets:
                    jobs = ((query, target, config),)
                    assert session.call(jobs) == [oracle.align(*jobs[0])]
                assert session.end_group() > 0
                assert session.worker.retained_bytes == session.worker.retained_entries == 0
        assert handles[1] > handles[0]
    finally:
        session.close()


def test_service_uses_variant_adapter_and_isolates_diagnostics(bend_binary, tmp_path, monkeypatch):
    from benchmarks.production_gate import Service, load_adapter
    import transport
    adapters = []
    for name in ("baseline", "candidate"):
        root = tmp_path / name
        root.mkdir()
        (root / "alignment.py").write_bytes((ROOT / "alignment.py").read_bytes())
        (root / "transport.py").write_text((ROOT / "transport.py").read_text() + '''
decode_count = 0
original_decode = decode_response
def decode_response(payload):
    global decode_count
    decode_count += 1
    return original_decode(payload)
''')
        adapter, metadata = load_adapter(root, tmp_path / (name + "-frozen"))
        assert metadata["sha256"]["transport.py"] == gates.digest((root / "transport.py").read_bytes())
        adapters.append(adapter)
    assert adapters[0].PreparedQuery is not adapters[1].PreparedQuery
    w = gates.Workload("isolation", ((b"AC", b"AC", AlignConfig()),))
    # A live/global adapter must never supply a variant service's decoder.
    monkeypatch.setattr(transport, "decode_response", lambda _: pytest.fail("global decoder used"))
    for index, adapter in enumerate(adapters):
        other = adapters[1 - index]
        before = other.decode_count
        session = Service(bend_binary, "owned-worker-single", w, 1, 1, 60,
                          observed=True, adapter=adapter)
        try:
            assert session.call(w.jobs)[0].edit_distance == 0
            assert adapter.decode_count == 1
            assert other.decode_count == before
            assert session.worker.codec_samples[0]["python_decode_ns"] > 0
            assert adapter.decode_response.__module__ == adapter.__name__
        finally:
            session.close()


def test_variant_adapter_rejects_changed_value_dependency(tmp_path):
    from benchmarks.production_gate import load_adapter
    (tmp_path / "transport.py").write_text("raise AssertionError('must not execute')")
    (tmp_path / "alignment.py").write_text("# changed types\n")
    with pytest.raises(RuntimeError, match="alignment.py differs"):
        load_adapter(tmp_path, tmp_path / "frozen")


def test_cpu_execution_observation_does_not_infer_parallelism_from_owners():
    from benchmarks.production_gate import cpu_observation
    observed = cpu_observation({11: 2, 12: 9, 13: 0, 14: 0}, {11: 2, 12: 14, 13: 0, 14: 0})
    assert observed["thread_cpu_ticks"] == {"11": 0, "12": 5, "13": 0, "14": 0}
    assert observed["positive_cpu_threads"] == 1
    assert observed["ticks_per_second"] > 0


def test_preparation_live_allocation_rounding(bend_tool, cpp_binary, tmp_path):
    from benchmarks.production_gate import Native
    from benchmarks.production_workloads import family
    binary, _ = gates.build(ROOT, tmp_path / 'memory', bend_tool,
        [str(ROOT / 'scripts/cc')], ['-std=c2x', '-O3', '-pthread'],
        entry_name='benchmarks/production_preparation.bend', allocations=True)
    q, config, batches = family('prep-irrelevant', 257, 0, 17)
    w = gates.Workload('memory', (), prepared_query=(q, config))
    session = Native(binary, 'prepare-batch', w, 1, 4, 60, 3)
    try:
        live = []
        for _ in range(3):
            actual, metrics = session.call(())
            assert actual == []
            assert metrics['request_latency_ns'] >= metrics['total_cost_ns']
            assert metrics['heap_phase3_peak_bytes'] >= metrics['heap_phase3_live_bytes']
            assert metrics['heap_phase7_live_bytes'] > metrics['heap_phase3_live_bytes']
            assert metrics['heap_allocated_bytes'] >= metrics['heap_peak_bytes'] - metrics['heap_live_start_bytes']
            live.append(metrics['heap_live_end_bytes'])
        assert max(live) - min(live) < 4096
        session.worker.finish()
    finally:
        session.close()


def test_isolated_production_profile_boundary(bend_tool, tmp_path):
    from benchmarks.production_gate import Native, applicable
    from benchmarks.production_workloads import family
    binary, meta = gates.build(ROOT, tmp_path / 'profile', bend_tool,
        [str(ROOT / 'scripts/cc')], ['-std=c2x', '-O3', '-pthread'],
        entry_name='benchmarks/profile_preparation.bend')
    q, config, _ = family('prep-irrelevant', 257, 0, 1)
    w = gates.Workload('profile', (), prepared_query=(q, config))
    assert applicable('profile-only', w) is None
    assert applicable('profile-only', replace(w, jobs=((q, q, config),)))
    assert applicable('profile-only', replace(w, prepared_query=(b'', config)))
    session = Native(binary, 'profile-only', w, 1, 4, 60, 2)
    try:
        for _ in range(2):
            actual, metrics = session.call(())
            assert actual == []
            assert metrics['effective_owners'] == 1
            assert metrics['profile_ns'] > 0 and metrics['search_ns'] > 0
            assert metrics['prepare_ns'] == metrics['work_ns'] == 0
            assert metrics['request_latency_ns'] >= metrics['total_cost_ns']
        session.worker.finish()
    finally:
        session.close()


def test_profile_scratch_trace_releases_temporary_adjacency(bend_tool, tmp_path):
    from benchmarks.production_gate import Native
    from benchmarks.production_workloads import family
    binary, _ = gates.build(ROOT, tmp_path / 'trace', bend_tool,
        [str(ROOT / 'scripts/cc')], ['-std=c2x', '-O3', '-pthread', '-DGATE_SCRATCH_TRACE=1'],
        entry_name='benchmarks/profile_preparation.bend', allocations=True)
    query, config, _ = family('prep-irrelevant', 257, 0, 7)
    workload = gates.Workload('trace', (), prepared_query=(query, config))
    session = Native(binary, 'profile-only', workload, 1, 1, 60, 2)
    try:
        for _ in range(2):
            _, metrics = session.call(())
            # 16,256 directed list nodes alone require at least 260,096
            # rounded bytes. They are temporary even when freed before masks.
            assert metrics['heap_scratch_peak_bytes'] >= 16256 * 16
            assert metrics['heap_temporary_allocated_bytes'] >= metrics['heap_scratch_peak_bytes']
            assert metrics['heap_retained_new_bytes'] >= 1024 + 256 * 16 * 4
            assert metrics['heap_trace_events'] > 2 * 16256
        session.worker.finish()
    finally:
        session.close()
