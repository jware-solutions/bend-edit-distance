"""Exercise release ranges and reruns without publishing anything to GitHub."""

import subprocess
import urllib.error
from pathlib import Path

import pytest

from scripts import release


@pytest.fixture
def history(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "version.txt").write_text("0.1.0\n", encoding="utf-8")
    subprocess.run(["git", "init", "--initial-branch=main"], check=True, capture_output=True)

    def commit(subject):
        path = tmp_path / "changes.txt"
        path.write_text(path.read_text() + subject + "\n" if path.exists() else subject + "\n")
        subprocess.run(["git", "add", "changes.txt"], check=True)
        subprocess.run([
            "git", "-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid",
            "commit", "-m", subject,
        ], check=True, capture_output=True)
        return release.git("rev-parse", "HEAD")

    return commit


def test_first_release_includes_every_commit(history):
    first = history("Initial implementation")
    head = history("Handle [literal] *characters*")
    notes = release.commit_notes("owner/project", head, None)
    assert first in notes and head in notes
    assert "Initial implementation" in notes
    assert r"Handle \[literal\] \*characters\*" in notes
    assert "changes.txt" in notes


def test_release_range_includes_all_unreleased_commits(history):
    old = history("Already released")
    release.git("tag", "build-1")
    first = history("First direct push")
    head = history("Second direct push")
    notes = release.commit_notes("owner/project", head, "build-1")
    assert old not in notes
    assert first in notes and head in notes
    assert "compare/build-1..." in notes


def test_previous_release_uses_ancestry_when_runs_finish_out_of_order(history, monkeypatch):
    history("First")
    release.git("tag", "build-1")
    head = history("Second")
    history("Newer push already released")
    release.git("tag", "build-3")
    monkeypatch.setattr(release, "api", lambda *args: [
        {"tag_name": tag, "draft": False, "prerelease": False}
        for tag in ["build-3", "build-1"]
    ])
    assert release.previous_release("owner/project", head) == "build-1"


@pytest.mark.parametrize("existing_tag", [False, True])
def test_publish_tags_exact_tested_sha_and_includes_direct_commits(history, monkeypatch, existing_tag):
    head = history("Direct commit without a PR")
    Path("version.txt").write_text("0.2.0\n", encoding="utf-8")
    if existing_tag:
        release.git("tag", "v0.2.0")
    calls = []

    def api(repository, path, payload=None):
        calls.append((path, payload))
        if path.startswith("releases/tags/"):
            raise urllib.error.HTTPError(path, 404, "Not found", {}, None)
        if path.startswith("releases?"):
            return []
        if path == "releases/generate-notes":
            return {"body": "## What's Changed\nGenerated PR notes"}
        return {"html_url": "https://github.com/owner/project/releases/tag/test"}

    monkeypatch.setattr(release, "api", api)
    release.publish("owner/project", head)
    path, payload = calls[-1]
    assert path == "releases"
    assert payload["tag_name"] == "v0.2.0"
    assert payload["name"] == "v0.2.0"
    assert payload["target_commitish"] == head
    assert "Generated PR notes" in payload["body"]
    assert "Direct commit without a PR" in payload["body"]


@pytest.mark.parametrize("fetched_tag", [False, True])
def test_release_rerun_is_idempotent(history, monkeypatch, fetched_tag):
    head = history("Release once")
    tag = "v0.1.0"
    if fetched_tag:
        release.git("tag", tag)
    calls = []

    def api(repository, path, payload=None):
        calls.append(path)
        return {"html_url": "https://example.invalid/release"}

    monkeypatch.setattr(release, "api", api)
    assert release.publish("owner/project", head) == "https://example.invalid/release"
    assert calls == [f"releases/tags/{tag}"]


def test_later_push_with_same_version_preserves_published_tag(history, monkeypatch):
    original = history("Released version")
    release.git("tag", "v0.1.0")
    head = history("Later push without a version bump")
    calls = []

    def api(repository, path, payload=None):
        calls.append(path)
        return {"html_url": "https://example.invalid/release"}

    monkeypatch.setattr(release, "api", api)
    assert release.publish("owner/project", head) == "https://example.invalid/release"
    assert calls == ["releases/tags/v0.1.0"]
    assert release.git("rev-parse", "refs/tags/v0.1.0") == original


@pytest.mark.parametrize("concurrent_release", [False, True])
def test_overlapping_pushes_only_reuse_a_release_that_exists(history, monkeypatch, concurrent_release):
    head = history("Overlapping push")
    creating = False

    def api(repository, path, payload=None):
        nonlocal creating
        if path.startswith("releases/tags/"):
            if creating and concurrent_release:
                return {"html_url": "https://example.invalid/concurrent-release"}
            raise urllib.error.HTTPError(path, 404, "Not found", {}, None)
        if path.startswith("releases?"):
            return []
        if path == "releases/generate-notes":
            return {"body": "Generated notes"}
        assert path == "releases"
        creating = True
        raise urllib.error.HTTPError(path, 422, "Validation failed", {}, None)

    monkeypatch.setattr(release, "api", api)
    if concurrent_release:
        assert release.publish("owner/project", head) == "https://example.invalid/concurrent-release"
    else:
        with pytest.raises(urllib.error.HTTPError, match="422"):
            release.publish("owner/project", head)


def test_version_tag_accepts_windows_line_endings(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "version.txt").write_bytes(b"0.12.34\r\n")
    assert release.version_tag() == "v0.12.34"


@pytest.mark.parametrize("version", ["", "1.2", "01.2.3", "v1.2.3", "1.2.3\n4.5.6", "../1.2.3"])
def test_invalid_version_is_rejected(tmp_path, monkeypatch, version):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "version.txt").write_text(version, encoding="utf-8")
    with pytest.raises(ValueError, match="version.txt"):
        release.version_tag()


def test_missing_version_file_is_rejected(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    with pytest.raises(FileNotFoundError, match="version.txt"):
        release.version_tag()


def test_release_api_errors_are_not_treated_as_missing(history, monkeypatch):
    head = history("Fail closed")

    def api(*args):
        raise urllib.error.HTTPError("url", 403, "Forbidden", {}, None)

    monkeypatch.setattr(release, "api", api)
    with pytest.raises(urllib.error.HTTPError, match="403"):
        release.publish("owner/project", head)


def test_publish_refuses_a_tag_at_the_wrong_commit_even_without_a_release(history, monkeypatch):
    old = history("Old commit")
    head = history("Commit that passed CI")
    release.git("tag", "v0.1.0", old)

    def no_release(repository, path, payload=None):
        assert path == "releases/tags/v0.1.0"
        raise urllib.error.HTTPError(path, 404, "Not found", {}, None)

    monkeypatch.setattr(release, "api", no_release)
    with pytest.raises(RuntimeError, match="different commit"):
        release.publish("owner/project", head)
