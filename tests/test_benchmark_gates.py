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
    source = gates.allocation_source(gates.ALLOC_ANCHOR + "\n}")
    assert "atomic_fetch_add_explicit" in source


def test_cuda_evidence_rejects_fallback():
    with pytest.raises(RuntimeError, match="fallback"):
        gates.check_device({"work_ns": 1}, True)
    gates.check_device(dict(work_ns=10, device_completed_bangs=1, device_scheduler_ns=8,
        device_sync_batches=2, device_rounds_submitted=3), True)


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
    from benchmarks.production_workloads import family, FAMILIES
    for name in FAMILIES:
        q, config, batches = family(name, 129, 8, 42)
        assert (q, config, batches) == family(name, 129, 8, 42)
        assert len(batches) == 3
        if name != "identical":
            assert len(set(batches)) == 3
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
        assert all(metrics[k] > 0 for k in ('planning_ns', 'work_ns', 'ordering_ns'))
        session.worker.finish()
    finally:
        session.close()
    search = Native(binary, 'search-diagnostic', w, 1, 1, 60, 1)
    try:
        values, metrics = search.call(w.jobs)
        assert all(r.edit_distance == 1 for r in values)
        assert metrics['search_ns'] > 0 and metrics['result_ns'] > 0
        search.worker.finish()
    finally:
        search.close()
    from alignment import MaxDistance
    from transport import AlignmentWorker
    with AlignmentWorker([cpp_binary, '--worker']) as oracle:
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


def test_production_cli_end_to_end(production_binaries, bend_binary, tmp_path, monkeypatch):
    from benchmarks import production_gate
    api, _, refs = production_binaries
    def build(root, directory, bend, cc, flags, **kwargs):
        binary = bend_binary if kwargs['entry_name'] == 'worker.bend' else api
        return binary, {'allocations': False, 'commands': [], 'binary_sha256': gates.digest(binary.read_bytes())}
    monkeypatch.setattr(gates, 'build', build)
    monkeypatch.setattr(production_gate, 'build_references', lambda *a: (refs, {}))
    output = tmp_path / 'production-results'
    code = gates.main(['--mode', 'owned-worker-batch', '--mode', 'ordinary-worker-batch', '--mode', 'string-batch',
        '--family', 'one:129', '--batch-sizes', '0', '1', '--reuse-counts', '1', '--threads', '1',
        '--warmups', '1', '--repeats', '2', '--max-regression', '100000', '--output', str(output)])
    assert code == 0
    document = json.loads((output / 'results.json').read_text())
    assert document['status'] == 'passed' and len(document['coverage']) == 6
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
            assert record['setup']['after_release_retained_budget_bytes'] == 0
    assert (output / 'summary.csv').exists()
    assert not (output / 'REPORT.md').exists()
    assert not (output / 'summary.md').exists()


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
