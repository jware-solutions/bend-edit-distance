"""Benchmark integrity checks, not timing thresholds or speedup assertions."""

import copy
import json

import pytest

from benchmarks.generate import corpus
from benchmarks.runner import ROOT, load_corpus, lookup_checksum, parse_output, summarize


def output():
    return "ready,100\n" + "".join(f"phase,{i},{i * 10}\n" for i in range(8)) + "checksum,3\nusage,90,200,1234,500\n"


def test_corpus_regenerates_exactly():
    assert corpus() == load_corpus(ROOT / "benchmarks/corpus.json")


@pytest.mark.parametrize("bad", [
    lambda text: text.replace("checksum,3\n", ""),
    lambda text: text + "checksum,3\n",
    lambda text: text.replace("phase,2,20", "phase,2,-20"),
    lambda text: text.replace("phase,2,20", "phase,1,20"),
    lambda text: text.replace("usage,90,200,1234,500\n", ""),
    lambda text: text + "junk\n",
])
def test_rejects_unusable_native_measurement(bad):
    with pytest.raises(RuntimeError):
        parse_output(bad(output()))


def test_parses_complete_native_measurement():
    ready, checksum, phases, usage = parse_output(output())
    assert (ready, checksum, usage) == (100, 3, [90, 200, 1234, 500])
    assert phases[3] == 30


@pytest.mark.parametrize("patch", [
    {"query": "\0"}, {"target": "Ā"}, {"query": "A" * 4097}, {"distance": -1},
    {"distance": True}, {"distance": 5000},
])
def test_corpus_rejects_unsupported_measurements(tmp_path, patch):
    data = {"schema": 1, "cases": [{"name": "case", "query": "AC", "target": "A", "distance": 1}]}
    data["cases"][0].update(patch)
    path = tmp_path / "corpus.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(ValueError):
        load_corpus(path)


def test_lookup_control_checksum_and_word_padding():
    case = {"query": "A" * 32 + "C", "target": "A" * 33}
    assert lookup_checksum(case, 8, tree=True) == ((0xffffffff + 0xfffffffe) * 33 * 8) & 0xffffffff
    assert lookup_checksum(case, 8, tree=False) == ord("A") * 2 * 33 * 8
    swapped = copy.copy(case)
    swapped["query"], swapped["target"] = case["target"], case["query"]
    # Equal lengths preserve orientation, as production does; this also
    # exercises a character absent from the query in the final block.
    assert lookup_checksum(swapped, 1, tree=True) == (32 * (0xffffffff + 0xffffffff) + 0xfffffffe) & 0xffffffff


def test_summary_keeps_dispersion_and_uses_nearest_rank_p95():
    report = summarize([{"work_ns": n, "peak_rss_kib": n * 2, "checksum": 7} for n in (10, 20, 100)])
    assert report["work_ns"] == {"median": 20, "min": 10, "max": 100, "p95": 100}
    assert "checksum" not in report


def test_toolchain_comparison_checks_locations_even_when_distance_matches(monkeypatch):
    from dataclasses import replace
    from types import SimpleNamespace

    from alignment import AlignConfig, AlignResult, Position
    from benchmarks import compare_toolchains as comparison

    expected = AlignResult.from_edlib({"status": 0, "edit_distance": 1,
                                      "end_locations": [0], "start_locations": None,
                                      "alignment": None, "cigar": None})
    wrong = replace(expected, end_locations=(Position(1),))
    workload = {"name": "location-regression", "mode": "demand",
                "jobs": [("A", "C", AlignConfig())], "distances": [1]}
    affinity = []
    monkeypatch.setattr(comparison.os, "sched_getaffinity", lambda pid: {0, 1})
    monkeypatch.setattr(comparison.os, "sched_setaffinity", lambda pid, cpus: affinity.append(set(cpus)))
    monkeypatch.setattr(comparison.subprocess, "run", lambda *a, **kw: SimpleNamespace(
        returncode=0, stdout=b"response", stderr=b""))
    monkeypatch.setattr(comparison, "decode_batch", lambda output, count: [wrong])
    with pytest.raises(RuntimeError, match="Full ordered result mismatch"):
        comparison.measure(ROOT / "unused", workload, 1, [0, 1], [expected], 1)
    assert affinity == [{0}, {0, 1}]


def test_toolchain_comparison_restores_affinity_after_timeout(monkeypatch):
    import subprocess

    from benchmarks import compare_toolchains as comparison

    affinity = []
    monkeypatch.setattr(comparison.os, "sched_getaffinity", lambda pid: {0, 1})
    monkeypatch.setattr(comparison.os, "sched_setaffinity", lambda pid, cpus: affinity.append(set(cpus)))

    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired("probe", 1)

    monkeypatch.setattr(comparison.subprocess, "run", timeout)
    workload = {"mode": "demand", "jobs": []}
    with pytest.raises(subprocess.TimeoutExpired):
        comparison.measure(ROOT / "unused", workload, 1, [0, 1], [], 1)
    assert affinity == [{0}, {0, 1}]
