# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo contains two standalone CLI tools for inspecting GitHub CI status from the terminal. Both require `gh` (GitHub CLI) and must be run inside a git repository.

- **`ci-status.sh`** — Bash script that displays check-run statuses for a commit, with colored icons, durations, and detail URLs (run `ci-status.sh -h` for flags). Behavior not covered by `--help`: watch mode is a native in-place display (no external `watch`) and exits with the same pass/fail code as a one-shot run; unknown options exit 2 with usage; arguments starting with `-` are never treated as a git ref.
  - `--porcelain` emits one uppercase token via a priority cascade (worst first): `UNAVAILABLE` (gh API error) → `ACTION_REQUIRED` → `FAILURE` → `CANCELLED` (cancelled/timed_out) → `BUILDING` (any non-completed) → `NEUTRAL` → `SUCCESS` → `SKIPPED` → `UNKNOWN` (no checks). This priority is distinct from the display's worstness sort. The token is prefixed `UPSTREAM_` when the upstream-commit fallback is used.
- **`ci-status.py`** — Python port of `ci-status.sh`. Supports `--watch`/`-w`, `--reverse`/`-r`, and `--quiet`/`-q`. Watch mode renders a native live-updating display (no external `watch`) and auto-exits once all checks complete. Accepts an optional git ref argument.
- **`ci-tests.py`** — Python script that downloads JUnit XML artifacts from failed CI runs and prints the individual failing test names. Outputs newline-separated when TTY, null-separated otherwise (for piping). Accepts an optional git ref argument.

Both tools share the same commit-resolution logic: resolve HEAD, then fall back to the upstream tracking commit if the local commit isn't pushed.

## Key implementation details

- `ci-status.sh` uses `gh api --paginate` with `--slurp` in jq to correctly sort across paginated results. Sorting is by conclusion priority (success → pending → skipped → cancelled → timed_out → failure → action_required), with alphabetical name as tiebreaker.
- `ci-tests.py` caches downloaded artifacts under `/tmp/ci-status-artifacts/{run_id}/` to avoid re-downloading.
- `ci-tests.py` converts JUnit `classname` attributes to pytest node IDs via `classname_to_node()`.

## Dependencies

- `gh` (GitHub CLI), `jq`, `git`
- `ci-status.py`'s pip dependencies are listed in `requirements.txt`

## Testing

- `test_ci_status_sh.py` — pytest suite for `ci-status.sh`. It runs the script as a subprocess with fake `gh` and `git` placed first on PATH (check-runs JSON, gh exit code, and the commit/upstream all driven by env vars), so no network or real git repo is needed. Covers the `--porcelain` state cascade (incl. `UPSTREAM_` prefix), exit codes, and the default/verbose/quiet display modes. Run with `python3 -m pytest` (dev deps in `requirements-dev.txt`).
- `ci-status.py` / `ci-tests.py` have no automated tests; run them directly against a git repo with GitHub CI.
