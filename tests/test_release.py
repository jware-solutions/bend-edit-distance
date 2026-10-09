"""Exercise release ranges and reruns without publishing anything to GitHub."""

import subprocess
import urllib.error

import pytest

from scripts import release


@pytest.fixture
def history(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
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


def test_publish_tags_exact_tested_sha_and_includes_direct_commits(history, monkeypatch):
    head = history("Direct commit without a PR")
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
    release.publish("owner/project", head, "42")
    path, payload = calls[-1]
    assert path == "releases"
    assert payload["tag_name"] == f"build-42-{head[:8]}"
    assert payload["target_commitish"] == head
    assert "Generated PR notes" in payload["body"]
    assert "Direct commit without a PR" in payload["body"]


def test_release_rerun_is_idempotent(history, monkeypatch):
    head = history("Release once")
    tag = f"build-42-{head[:8]}"
    release.git("tag", tag)
    calls = []

    def api(repository, path, payload=None):
        calls.append(path)
        return {"html_url": "https://example.invalid/release"}

    monkeypatch.setattr(release, "api", api)
    assert release.publish("owner/project", head, "42") == "https://example.invalid/release"
    assert calls == [f"releases/tags/{tag}"]


def test_release_api_errors_are_not_treated_as_missing(history, monkeypatch):
    head = history("Fail closed")

    def api(*args):
        raise urllib.error.HTTPError("url", 403, "Forbidden", {}, None)

    monkeypatch.setattr(release, "api", api)
    with pytest.raises(urllib.error.HTTPError, match="403"):
        release.publish("owner/project", head, "42")


def test_publish_refuses_a_tag_at_the_wrong_commit_even_without_a_release(history, monkeypatch):
    old = history("Old commit")
    head = history("Commit that passed CI")
    release.git("tag", f"build-42-{head[:8]}", old)
    def no_api(*args):
        pytest.fail("A mismatched tag must fail before contacting GitHub")

    monkeypatch.setattr(release, "api", no_api)
    with pytest.raises(RuntimeError, match="different commit"):
        release.publish("owner/project", head, "42")
