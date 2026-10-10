"""Publish the version in version.txt after successful main-push CI, using stdlib."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True, encoding="utf-8").strip()


def api(repository: str, path: str, payload: dict | None = None):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def previous_release(repository: str, sha: str) -> str | None:
    # Select by commit ancestry, not API date: overlapping push runs may finish
    # out of order, and a newer release must never become an older run's base.
    tags = {}
    page = 1
    while True:
        releases = api(repository, f"releases?per_page=100&page={page}")
        for release in releases:
            if release["draft"] or release["prerelease"]:
                continue
            tag = release["tag_name"]
            try:
                commit = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
            except subprocess.CalledProcessError:
                continue
            tags[commit] = tag
        if len(releases) < 100:
            break
        page += 1
    for commit in git("rev-list", "--first-parent", sha).splitlines()[1:]:
        if commit in tags:
            return tags[commit]
    return None


def commit_notes(repository: str, sha: str, previous: str | None) -> str:
    revision = f"refs/tags/{previous}..{sha}" if previous else sha
    commits = git("log", "--reverse", "--format=%H%x00%s", revision)
    lines = ["## Commits", ""]
    for commit in commits.splitlines():
        commit_sha, subject = commit.split("\0", 1)
        # Commit subjects are Markdown content, never shell commands or headings.
        subject = re.sub(r"([\\`*_{}\[\]<>])", r"\\\1", subject)
        lines.append(f"- {subject} ([{commit_sha[:8]}](https://github.com/{repository}/commit/{commit_sha}))")
    if previous:
        base = git("rev-parse", f"refs/tags/{previous}^{{commit}}")
        lines += ["", f"[All changes](https://github.com/{repository}/compare/{previous}...{sha})"]
    else:
        # Git computes the correct empty-tree ID even for a SHA-256 repository.
        base = subprocess.check_output(["git", "hash-object", "-t", "tree", "--stdin"], input=b"").decode().strip()
    lines += ["", "## Changed files", "", "```text", git("diff", "--stat", base, sha), "```", ""]
    return "\n".join(lines)


def version_tag() -> str:
    version = Path("version.txt").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?", version):
        raise ValueError("version.txt must contain a version number in MAJOR.MINOR.PATCH[.BUILD] format")
    return f"v{version}"


def publish(repository: str, sha: str) -> str:
    tag = version_tag()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected a full commit SHA")
    if git("rev-parse", "HEAD") != sha:
        raise RuntimeError("The checkout must be at the commit that passed CI")
    try:
        existing = api(repository, f"releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        # Reruns and later pushes with the same version keep the original release.
        return existing["html_url"]

    tagged = subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"])
    if tagged.returncode not in (0, 1):
        tagged.check_returncode()
    if tagged.returncode == 0 and git("rev-parse", f"refs/tags/{tag}^{{commit}}") != sha:
        raise RuntimeError(f"Existing tag {tag} points to a different commit")

    previous = previous_release(repository, sha)
    payload = {"tag_name": tag, "target_commitish": sha}
    if previous:
        payload["previous_tag_name"] = previous
    generated = api(repository, "releases/generate-notes", payload)
    body = generated["body"] + "\n\n" + commit_notes(repository, sha, previous)
    try:
        release = api(repository, "releases", {
            "tag_name": tag,
            "target_commitish": sha,
            "name": tag,
            "body": body,
            "draft": False,
            "prerelease": False,
        })
    except urllib.error.HTTPError as error:
        if error.code != 422:
            raise
        # Another successful push with this version may have published first.
        try:
            release = api(repository, f"releases/tags/{tag}")
        except urllib.error.HTTPError as lookup_error:
            if lookup_error.code == 404:
                raise error from lookup_error
            raise
    return release["html_url"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Write local commit notes; no GitHub calls")
    parser.add_argument("--previous-tag", help="Base tag for the local dry-run preview")
    args = parser.parse_args()
    repository = os.environ["GH_REPO"]
    sha = os.environ.get("RELEASE_SHA") or git("rev-parse", "HEAD")
    if args.dry_run:
        Path("build").mkdir(exist_ok=True)
        path = Path("build/release-notes.md")
        path.write_text(commit_notes(repository, sha, args.previous_tag), encoding="utf-8")
        print(path)
    else:
        print(publish(repository, sha))


if __name__ == "__main__":
    main()
