#!/usr/bin/env python3
"""Print failed tests from CI JUnit XML artifacts."""

import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CACHE_DIR = Path("/tmp/ci-status-artifacts")

IS_TTY = sys.stdout.isatty()
GREY = "\033[0;30m"
RESET = "\033[0m"


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def get_commit(git_ref=None):
    commit = run(["git", "rev-parse", "--verify", git_ref or "HEAD"])
    if not commit:
        return None
    if not git_ref:
        upstream = run(["git", "rev-parse", "--verify", "@{u}"])
        if upstream and upstream != commit:
            is_ancestor = (
                subprocess.run(
                    ["git", "merge-base", "--is-ancestor", commit, upstream],
                    capture_output=True,
                ).returncode
                == 0
            )
            if not is_ancestor:
                commit = upstream
    return commit


def get_failed_run_ids(repo, commit):
    lines = run(
        [
            "gh",
            "api",
            "--paginate",
            f"/repos/{repo}/commits/{commit}/check-runs",
            "-H",
            "Accept: application/vnd.github+json",
            "--jq",
            '.check_runs[] | select(.conclusion == "failure") | .details_url',
        ]
    )
    if not lines:
        return set()
    run_ids = set()
    for url in lines.splitlines():
        m = re.search(r"/runs/(\d+)", url)
        if m:
            run_ids.add(m.group(1))
    return run_ids


def download_artifacts(repo, run_id):
    artifact_dir = CACHE_DIR / str(run_id)
    if not artifact_dir.is_dir():
        artifact_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "gh",
                "run",
                "download",
                str(run_id),
                "--repo",
                repo,
                "--dir",
                str(artifact_dir),
            ],
            capture_output=True,
        )
    return artifact_dir


def classname_to_node(classname, name):
    if not classname:
        parts = name.split(".")
        return "/".join(parts[:-1]) if len(parts) > 1 else name
    parts = classname.split(".")
    i = len(parts)
    while i > 0 and parts[i - 1][:1].isupper():
        i -= 1
    module_parts, class_parts = parts[:i], parts[i:]
    if module_parts:
        node = "/".join(module_parts) + ".py"
        if class_parts:
            node += "::" + "::".join(class_parts)
        return f"{node}::{name}"
    if class_parts:
        return "::".join(class_parts) + "::" + name
    return name


def parse_failures(artifact_dir):
    failures = set()
    for xml_path in Path(artifact_dir).rglob("*.xml"):
        try:
            tree = ET.parse(xml_path)
        except Exception:
            continue
        for tc in tree.iter("testcase"):
            if tc.find("failure") is not None or tc.find("error") is not None:
                failures.add(
                    classname_to_node(
                        tc.get("classname", ""),
                        tc.get("name", ""),
                    )
                )
    return failures


def main():
    git_ref = None
    repo = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] in ("--repo", "-R") and i + 1 < len(args):
            repo = args[i + 1]
            i += 2
        else:
            git_ref = args[i]
            i += 1

    if not repo:
        repo = run(
            [
                "gh",
                "repo",
                "view",
                "--json",
                "owner,name",
                "--jq",
                '.owner.login + "/" + .name',
            ]
        )
    if not repo:
        print("Could not determine repository.", file=sys.stderr)
        sys.exit(1)

    commit = get_commit(git_ref)
    if not commit:
        print("No commit specified or detected.", file=sys.stderr)
        sys.exit(1)

    run_ids = get_failed_run_ids(repo, commit)
    if not run_ids:
        if IS_TTY:
            print(f"{GREY}No failing runs{RESET}")
        sys.exit(0)

    all_failures = set()
    for run_id in run_ids:
        all_failures.update(parse_failures(download_artifacts(repo, run_id)))

    if not all_failures:
        if IS_TTY:
            print(f"{GREY}No failing tests{RESET}")
        sys.exit(0)

    sep = "\n" if IS_TTY else "\0"
    for f in sorted(all_failures):
        print(f, end=sep)

    sys.exit(1)


if __name__ == "__main__":
    main()
