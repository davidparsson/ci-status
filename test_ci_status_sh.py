"""Unit tests for ci-status.sh.

The script is exercised end-to-end as a subprocess. Its external commands are
replaced by fakes placed first on PATH: `gh` (the GitHub API) and `git` (commit
resolution). Both are driven entirely by environment variables, so the tests
need neither network access nor a real git repository. By default `git` reports
a commit with no upstream, so there is no UPSTREAM_ prefix.

stdin is /dev/null so `stty size` reports nothing and `terminal_width` is empty:
detail-row URLs therefore always wrap onto the following line, keeping the
expected output deterministic regardless of the terminal pytest runs in.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent / "ci-status.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*m")

# Icons as they appear once ANSI colour is stripped (see icon_for_conclusion).
CHECK = "✔︎"  # success, neutral
CROSS = "✖︎"  # failure, cancelled, timed_out
WARN = "⚠"    # action_required
DASH = "—"    # skipped, unknown conclusion
DOT = "•"     # in-progress / building

# Fake gh: `gh repo view ...` prints the repo; `gh api ...` prints the canned
# JSON and exits with the requested code. Everything is driven by env vars.
FAKE_GH = """#!/usr/bin/env bash
case "$1" in
    repo) printf '%s\\n' "$FAKE_GH_REPO" ;;
    api)  printf '%s' "$FAKE_GH_JSON"; exit "${FAKE_GH_EXIT:-0}" ;;
    *)    exit 1 ;;
esac
"""

# Fake git for the three read-only commands the script runs. `rev-parse --verify
# @{u}` reports the upstream commit (or fails if unset); any other rev-parse
# reports HEAD; `merge-base --is-ancestor` returns the configured exit code.
FAKE_GIT = """#!/usr/bin/env bash
case "$1 $2" in
    "rev-parse --verify")
        if [[ "$3" == "@{u}" ]]; then
            [[ -n "$FAKE_GIT_UPSTREAM" ]] || exit 1
            printf '%s\\n' "$FAKE_GIT_UPSTREAM"
        else
            printf '%s\\n' "${FAKE_GIT_COMMIT:-headsha}"
        fi ;;
    "merge-base --is-ancestor") exit "${FAKE_GIT_IS_ANCESTOR:-0}" ;;
    *) exit 0 ;;
esac
"""

def strip_ansi(text):
    return ANSI.sub("", text)


def check(name, status, conclusion, **extra):
    """Build one check-run object. conclusion=None becomes JSON null (pending)."""
    run = {
        "name": name,
        "status": status,
        "conclusion": conclusion,
        "details_url": f"https://ci.test/{name}",
    }
    run.update(extra)
    return run


def row(icon, name, first="", second=""):
    """Expected detail row (URL wrapped to its own line), matching the printf."""
    display = name if len(name) <= 60 else name[:57] + "..."
    url = f"https://ci.test/{name}"
    return f"{icon}  {display:<60} {first:>4} {second:>3}\n   {url}\n"


def summary(icon, count, total, label):
    """Expected one-line summary, matching the printf."""
    head = f"All {total}" if count == total else f"{count} of {total}"
    return f"{icon}  {head} checks {label}\n"


@pytest.fixture(scope="session")
def fake_bin(tmp_path_factory):
    """Directory of fake `gh`/`git` placed first on PATH. The fakes are static
    (all behaviour is env-driven), so they're written once for the whole run."""
    bindir = tmp_path_factory.mktemp("bin")
    for name, body in (("gh", FAKE_GH), ("git", FAKE_GIT)):
        fake = bindir / name
        fake.write_text(body)
        fake.chmod(0o755)
    return bindir


@pytest.fixture
def run(fake_bin):
    """Return a callable that runs ci-status.sh against a given set of check-runs.

    `upstream` (a commit string) plus `is_ancestor=False` exercise the upstream
    fallback that adds the UPSTREAM_ prefix; the defaults leave it off.
    """
    def _run(check_runs, *args, gh_exit=0, repo_name="octocat/hello",
             upstream=None, is_ancestor=True):
        env = dict(os.environ)
        env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
        env["FAKE_GH_REPO"] = repo_name
        env["FAKE_GH_JSON"] = json.dumps({"check_runs": check_runs})
        env["FAKE_GH_EXIT"] = str(gh_exit)
        env["FAKE_GIT_COMMIT"] = "headsha"
        env["FAKE_GIT_UPSTREAM"] = upstream or ""
        env["FAKE_GIT_IS_ANCESTOR"] = "0" if is_ancestor else "1"
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )

    return _run


# --- --porcelain state cascade -------------------------------------------------

@pytest.mark.parametrize(
    "check_runs, expected",
    [
        ([check("a", "completed", "success"), check("b", "completed", "success")], "SUCCESS"),
        ([check("a", "completed", "success"), check("b", "completed", "skipped")], "SUCCESS"),
        ([check("a", "completed", "skipped")], "SKIPPED"),
        ([check("a", "completed", "neutral"), check("b", "completed", "success")], "NEUTRAL"),
        ([check("a", "in_progress", None), check("b", "completed", "success")], "BUILDING"),
        ([check("a", "in_progress", None), check("b", "completed", "failure")], "FAILURE"),
        ([check("a", "completed", "timed_out")], "CANCELLED"),
        ([check("a", "completed", "cancelled")], "CANCELLED"),
        ([check("a", "completed", "failure"), check("b", "completed", "action_required")], "ACTION_REQUIRED"),
        ([], "UNKNOWN"),
    ],
)
def test_porcelain_state(run, check_runs, expected):
    result = run(check_runs, "--porcelain")
    assert result.stdout == expected + "\n"


def test_porcelain_unavailable_on_gh_error(run):
    result = run([], "-p", gh_exit=1)
    assert result.stdout == "UNAVAILABLE\n"


def test_porcelain_upstream_prefix(run):
    # HEAD isn't an ancestor of its upstream -> the script checks the upstream
    # commit and prefixes the state with UPSTREAM_.
    result = run([check("a", "completed", "failure")], "-p",
                 upstream="upstreamsha", is_ancestor=False)
    assert result.stdout == "UPSTREAM_FAILURE\n"


# --- exit codes ----------------------------------------------------------------

def test_exit_zero_when_all_pass(run):
    assert run([check("a", "completed", "success")]).returncode == 0


def test_exit_zero_with_skipped(run):
    runs = [check("a", "completed", "success"), check("b", "completed", "skipped")]
    assert run(runs).returncode == 0


def test_exit_one_on_failure(run):
    runs = [check("a", "completed", "success"), check("b", "completed", "failure")]
    assert run(runs).returncode == 1


def test_no_status(run):
    result = run([])
    assert result.returncode == 1
    assert strip_ansi(result.stdout) == "No status\n"


# --- default / verbose / quiet display -----------------------------------------

def test_default_collapses_passing_lists_problems(run):
    runs = [check(f"unit {i}", "completed", "success") for i in range(38)]
    runs.append(check("integration", "completed", "failure"))
    result = run(runs)
    expected = summary(CHECK, 38, 39, "passed") + row(CROSS, "integration")
    assert strip_ansi(result.stdout) == expected
    assert result.stderr == ""
    assert result.returncode == 1


def test_default_all_passing_is_summary_only(run):
    runs = [check("a", "completed", "success"), check("b", "completed", "success")]
    result = run(runs)
    assert strip_ansi(result.stdout) == summary(CHECK, 2, 2, "passed")
    assert result.stderr == ""
    assert result.returncode == 0


def test_verbose_lists_every_check(run):
    runs = [check("alpha", "completed", "success"), check("beta", "completed", "failure")]
    result = run(runs, "--verbose")
    expected = row(CHECK, "alpha") + row(CROSS, "beta")
    assert strip_ansi(result.stdout) == expected
    assert result.stderr == ""


def test_quiet_summarizes_every_status(run):
    runs = [check("alpha", "completed", "success"), check("beta", "completed", "failure")]
    result = run(runs, "--quiet")
    expected = summary(CHECK, 1, 2, "passed") + summary(CROSS, 1, 2, "failed")
    assert strip_ansi(result.stdout) == expected
    assert result.stderr == ""


def test_quiet_mixed_statuses_full_output(run):
    runs = [
        check("a", "completed", "success"),
        check("b", "in_progress", None),
        check("c", "completed", "skipped"),
        check("d", "completed", "failure"),
        check("e", "completed", "action_required"),
    ]
    result = run(runs, "-q")
    expected = (
        summary(CHECK, 1, 5, "passed")
        + summary(DOT, 1, 5, "pending")
        + summary(DASH, 1, 5, "skipped")
        + summary(CROSS, 1, 5, "failed")
        + summary(WARN, 1, 5, "action required")
    )
    assert strip_ansi(result.stdout) == expected


def test_quiet_all_one_status_says_all(run):
    runs = [check("a", "completed", "success"), check("b", "completed", "success")]
    assert strip_ansi(run(runs, "-q").stdout) == summary(CHECK, 2, 2, "passed")


def test_reverse_flips_order(run):
    runs = [check("a", "completed", "success"), check("b", "completed", "failure")]
    forward = summary(CHECK, 1, 2, "passed") + summary(CROSS, 1, 2, "failed")
    reverse = summary(CROSS, 1, 2, "failed") + summary(CHECK, 1, 2, "passed")
    assert strip_ansi(run(runs, "-q").stdout) == forward
    assert strip_ansi(run(runs, "-q", "-r").stdout) == reverse


def test_duration_is_formatted(run):
    runs = [check("slow", "completed", "failure",
                  started_at="2026-06-11T10:00:00Z",
                  completed_at="2026-06-11T10:04:11Z")]
    result = run(runs, "-v")
    assert strip_ansi(result.stdout) == row(CROSS, "slow", "4m", "11s")


# --- argument handling ---------------------------------------------------------

def test_help_prints_usage_and_exits_zero(run):
    result = run([], "--help")
    assert result.returncode == 0
    assert result.stderr == ""
    assert result.stdout.startswith("Usage: ci-status.sh")
    for flag in ("--watch", "--reverse", "--verbose", "--quiet", "--porcelain", "--help"):
        assert flag in result.stdout


def test_unknown_option_errors_with_usage(run):
    result = run([], "--bogus")
    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr.startswith("Unknown option: --bogus\n")
    assert "Usage: ci-status.sh" in result.stderr
