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
    monkeypatch.setattr(gates, "build", lambda *a, **kw: (binary, metadata))
    output = tmp_path / "results"
    code = gates.main(["--threads", "1", "--batch-sizes", "1", "--reuse-counts", "1",
        "--workload", "example/1", "--warmups", "1", "--repeats", "2",
        "--max-regression", "100000", "--output", str(output)])
    assert code == 0
    document = json.loads((output / "results.json").read_text())
    assert document["status"] == "passed"
    assert len(document["records"]) == 8
    for record in document["records"]:
        assert [s["repetition"] for s in record["samples"]] == [0, 1]
        assert [s["order"] for s in record["samples"]] == ([1, 0] if record["variant"] == "baseline" else [0, 1])
        assert record["affinity_cpus"] == document["environment"]["selected_cpus"][:1]
        for sample in record["samples"]:
            assert "heap_alloc_calls" not in sample
    assert {p.suffix for p in output.iterdir()} == {".json", ".csv"}
    assert not Path(metadata["commands"][1][-1]).is_relative_to(ROOT)
