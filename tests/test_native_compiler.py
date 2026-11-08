"""The project CC wrapper preserves executable paths, arguments and failures."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from bend_runtime import configure_toolchain

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("status", [0, 27])
def test_compiler_wrapper_arguments_and_status(tmp_path, status):
    compiler = tmp_path / "compiler with spaces"
    compiler.write_text(
        f"#!{sys.executable}\nimport json, sys\n"
        f"print(json.dumps(sys.argv[1:]))\nsys.exit({status})\n")
    compiler.chmod(0o755)
    arguments = ["-std=c2x", "source with spaces.c", "-o", "literal $() `name`"]
    result = subprocess.run([ROOT / "scripts/cc", *arguments],
        env={**os.environ, "BEND_CC": str(compiler)}, capture_output=True, text=True)
    assert result.returncode == status
    assert json.loads(result.stdout) == [
        "-mllvm", "-inline-threshold=1000", "-mllvm",
        "-inlinehint-threshold=2000", *arguments]
    assert result.stderr == ""


def test_explicit_invalid_compiler_is_rejected(monkeypatch, tmp_path):
    missing = str(tmp_path / "missing compiler")
    monkeypatch.setenv("CC", missing)
    with pytest.raises(RuntimeError, match="is not runnable"):
        configure_toolchain(ROOT)
    assert os.environ["CC"] == missing


def test_explicit_compiler_remains_authoritative(monkeypatch):
    monkeypatch.setenv("CC", "clang-19")
    monkeypatch.setenv("BEND_CC", "/not/a/compiler")
    configure_toolchain(ROOT)
    assert os.environ["CC"] == "clang-19"


def test_compiler_provenance_resolves_wrapper(monkeypatch):
    from benchmarks.production_gate import executable
    compiler = executable('clang-19')
    assert Path(compiler['path']).is_absolute()
    assert len(compiler['sha256']) == 64
    assert 'clang version 19' in compiler['version']


def test_gate_keeps_explicit_compiler_paths_with_spaces(tmp_path):
    from benchmarks.gates import compiler_command
    compiler = tmp_path / 'compiler with spaces'
    compiler.write_text('#!/bin/sh\nexit 0\n')
    assert compiler_command(str(compiler)) == [str(compiler)]
    assert compiler_command('clang-19 -fno-inline') == ['clang-19', '-fno-inline']


def compiler_stub(tmp_path, version):
    path = tmp_path / version / 'bin' / 'bend'
    path.parent.mkdir(parents=True)
    path.write_text(f'#!{sys.executable}\nimport pathlib,sys\n'
        f'if sys.argv[1:] == ["version"]: print("bend {version}")\n'
        f'else: pathlib.Path(sys.argv[sys.argv.index("-o")+1]).write_text("int main(void){{return {int(version.rsplit(".",1)[1])};}}\\n")\n')
    path.chmod(0o755)
    bundled = path.parent.parent / 'bend2'
    bundled.mkdir()
    (bundled / 'base.bend').write_text('Base ' + version)
    (bundled / 'bendtt.lean').write_text('Kernel ' + version)
    (path.parent.parent / '.bend-version').write_text(version + '\n')
    return path


def selection_args(reference):
    from benchmarks import gates
    root = str(reference.parent.parent)
    return gates.parser(False).parse_args(['--bend', str(reference), '--baseline', root, '--candidate', root])


def test_gate_compiler_selection_defaults_and_intent(tmp_path):
    from benchmarks import gates
    reference = compiler_stub(tmp_path, '2.0.39')
    candidate = compiler_stub(tmp_path, '2.0.40')
    args = selection_args(reference)
    selections = gates.select_compilers(args)
    assert {s['path'] for s in selections.values()} == {str(reference)}
    assert not any(s['release_override'] for s in selections.values())
    args.candidate_bend = str(candidate)
    with pytest.raises(RuntimeError, match='candidate compiler mismatch'):
        gates.select_compilers(args)
    args.candidate_bend_version = '2.0.40'
    selections = gates.select_compilers(args)
    assert selections['baseline']['expected_release'] == '2.0.39'
    assert selections['candidate']['release_override']
    assert selections['candidate']['source_pin'] == '2.0.39'
    assert selections['candidate']['sha256'] != selections['baseline']['sha256']
    assert selections['candidate']['bundled_sources_sha256'] != selections['baseline']['bundled_sources_sha256']


@pytest.mark.parametrize('command,expected,error', [
    (None, '2.0.40', 'requires'), ('missing', None, 'not executable'),
    ('stub', '2.0.41', 'compiler mismatch'), ('stub', '2.0.40 fork', 'Invalid expected')])
def test_gate_invalid_compiler_selection(tmp_path, command, expected, error):
    from benchmarks import gates
    reference = compiler_stub(tmp_path, '2.0.39')
    args = selection_args(reference)
    args.candidate_bend = str(reference) if command == 'stub' else command
    args.candidate_bend_version = expected
    with pytest.raises((ValueError, RuntimeError), match=error):
        gates.select_compilers(args)


def test_common_compiler_still_checks_both_pins(tmp_path):
    from benchmarks import gates
    reference = compiler_stub(tmp_path, '2.0.39')
    (tmp_path / '.bend-version').write_text('2.0.40\n')
    args = selection_args(reference)
    args.candidate = tmp_path
    with pytest.raises(RuntimeError, match='candidate compiler mismatch'):
        gates.select_compilers(args)


def test_compiler_build_outputs_are_fresh_and_separate(tmp_path):
    from benchmarks import gates
    outputs = []
    for version in ('2.0.39', '2.0.40'):
        compiler = compiler_stub(tmp_path, version)
        directory = tmp_path / ('build-' + version)
        binary, meta = gates.build(ROOT, directory, compiler, [str(ROOT / 'scripts/cc')], ['-std=c2x', '-O1'])
        assert subprocess.run([binary]).returncode == int(version.rsplit('.', 1)[1])
        assert meta['bend']['path'] == str(compiler)
        assert meta['bend']['version'] == 'bend ' + version
        assert Path(meta['commands'][0][0]) == compiler
        assert (directory / 'probe.c').exists()
        assert meta['host_driver_trace'].count('inline-threshold=1000') == 1
        assert meta['host_driver_trace'].count('inlinehint-threshold=2000') == 1
        outputs.append(meta['binary_sha256'])
        with pytest.raises(FileExistsError):
            gates.build(ROOT, directory, compiler, ['clang-19'], ['-O1'])
    assert outputs[0] != outputs[1]


def test_missing_emission_cannot_reuse_a_binary(tmp_path):
    from benchmarks import gates
    compiler = tmp_path / 'no-output-bend'
    compiler.write_text('#!/bin/sh\nif [ "$1" = version ]; then echo "bend 2.0.39"; fi\nexit 0\n')
    compiler.chmod(0o755)
    directory = tmp_path / 'failed-build'
    directory.mkdir()
    (directory / 'probe').write_bytes(b'stale binary')
    with pytest.raises(FileNotFoundError):
        gates.build(ROOT, directory, compiler, ['clang-19'], ['-O3'])


def test_selected_compiler_change_rejected_before_build(tmp_path):
    from benchmarks import gates
    compiler = compiler_stub(tmp_path, '2.0.39')
    identity = gates.select_compilers(selection_args(compiler))['baseline']
    compiler.write_text(compiler.read_text() + '# changed executable\n')
    with pytest.raises(RuntimeError, match='compiler changed before build'):
        gates.build(ROOT, tmp_path / 'changed-build', compiler, ['clang-19'], ['-O3'], compiler_identity=identity)
    assert not (tmp_path / 'changed-build').exists()


def test_compiler_mismatch_is_recorded_before_any_build(tmp_path, monkeypatch):
    from benchmarks import gates
    compiler = compiler_stub(tmp_path, '2.0.40')
    source = tmp_path / 'source'
    source.mkdir()
    (source / '.bend-version').write_text('2.0.39\n')
    output = tmp_path / 'rejected-results'
    def unexpected(*args, **kwargs):
        pytest.fail('A mismatched compiler reached a build')
    monkeypatch.setattr(gates, 'build', unexpected)
    with pytest.raises(RuntimeError, match='compiler mismatch'):
        gates.main(['--baseline', str(source), '--candidate', str(source),
            '--bend', str(compiler), '--threads', '1', '--output', str(output)])
    document = json.loads((output / 'results.json').read_text())
    assert document['status'] == 'failed'
    assert 'compiler mismatch' in document['reason']
    assert document['records'] == []
