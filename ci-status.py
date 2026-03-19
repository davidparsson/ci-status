#!/usr/bin/env python3
"""Display CI check-run statuses for a commit."""

import json
import shutil
import subprocess
import sys
import time

RESET = "\033[0m"
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
GREY = "\033[0;30m"
CYAN = "\033[0;36m"


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
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


def icon_for_conclusion(conclusion):
    return {
        "success": f"{GREEN}✔︎{RESET}",
        "failure": f"{RED}✖︎{RESET}",
        "cancelled": f"{GREY}✖︎{RESET}",
        "neutral": f"{BLUE}✔︎{RESET}",
        "timed_out": f"{YELLOW}✖︎{RESET}",
        "action_required": f"{YELLOW}⚠{RESET}",
        "skipped": f"{GREY}—{RESET}",
    }.get(conclusion, f"{YELLOW}—{RESET}")


def build_icon(status, conclusion):
    if status == "completed":
        return icon_for_conclusion(conclusion)
    return f"{YELLOW}•{RESET}"


CONCLUSION_PRIORITY = {
    "success": 1,
    "neutral": 2,
    "skipped": 4,
    "cancelled": 5,
    "timed_out": 6,
    "failure": 7,
    "action_required": 8,
}


def conclusion_sort_key(check_run):
    return CONCLUSION_PRIORITY.get(check_run.get("conclusion") or "", 3)


def format_duration(started_at, completed_at):
    if not started_at or not completed_at:
        return "", ""
    from datetime import datetime, timezone

    time_format = "%Y-%m-%dT%H:%M:%SZ"
    try:
        start = datetime.strptime(started_at, time_format).replace(tzinfo=timezone.utc)
        end = datetime.strptime(completed_at, time_format).replace(tzinfo=timezone.utc)
    except ValueError:
        return "", ""
    total = int((end - start).total_seconds())
    if total < 0:
        return "", ""
    seconds = total % 60
    second_part = f"{seconds}s"
    first_part = f"{total // 60}m" if total >= 60 else ""
    return first_part, second_part


def terminal_width():
    size = shutil.get_terminal_size((80, 24))
    return size.columns


def main():
    watch = False
    reverse = False
    quiet = False
    git_ref = None

    for arg in sys.argv[1:]:
        if arg in ("--watch", "-w"):
            watch = True
        elif arg in ("--reverse", "-r"):
            reverse = True
        elif arg in ("--quiet", "-q"):
            quiet = True
        else:
            git_ref = arg

    if watch:
        def clear_screen():
            sys.stdout.write("\033[H\033[2J")
            sys.stdout.flush()

        while True:
            display(reverse, quiet, git_ref, before_render=clear_screen)
            try:
                time.sleep(2)
            except KeyboardInterrupt:
                break
        sys.exit(0)

    sys.exit(display(reverse, quiet, git_ref))


def display(reverse, quiet, git_ref, before_render=None):
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
        return 1

    commit = get_commit(git_ref)
    if not commit:
        print("No commit specified or detected.", file=sys.stderr)
        return 1

    api_path = f"/repos/{repo}/commits/{commit}/check-runs"
    raw = run(
        [
            "gh",
            "api",
            "--paginate",
            f"{api_path}?per_page=100",
            "-H",
            "Accept: application/vnd.github+json",
        ]
    )
    if not raw:
        print(f"{GREY}No status{RESET}")
        return 1

    # gh --paginate emits one JSON object per page; collect all check_runs
    check_runs = []
    for line in raw.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            page = json.loads(line)
            check_runs.extend(page.get("check_runs", []))
        except json.JSONDecodeError:
            continue

    if not check_runs:
        print(f"{GREY}No status{RESET}")
        return 1

    if before_render:
        before_render()

    # Sort: by conclusion priority, then alphabetically by name
    check_runs.sort(key=lambda check_run: (conclusion_sort_key(check_run), (check_run.get("name") or "").lower()))
    if reverse:
        check_runs.reverse()

    width = terminal_width()
    all_success = True
    success_count = 0

    for check_run in check_runs:
        conclusion = check_run.get("conclusion") or "pending"
        if conclusion == "success":
            success_count += 1
        elif conclusion != "skipped":
            all_success = False

    # Compute name column width: longest name (capped at 60)
    name_column = 0
    for check_run in check_runs:
        if quiet and (check_run.get("conclusion") or "pending") == "success":
            continue
        name_column = max(name_column, len(check_run.get("name") or "-"))
    name_column = min(name_column, 60)

    if quiet and success_count:
        icon = icon_for_conclusion("success")
        label = f"All {success_count} jobs" if all_success else f"{success_count} jobs"
        print(f"{icon}  {label} passed")

    for check_run in check_runs:
        status = check_run.get("status", "unknown")
        conclusion = check_run.get("conclusion") or "pending"
        if quiet and conclusion == "success":
            continue

        name = check_run.get("name") or "-"
        details_url = check_run.get("details_url") or "-"
        started_at = check_run.get("started_at")
        completed_at = check_run.get("completed_at")

        icon = build_icon(status, conclusion)

        if len(name) > 60:
            name = name[:57] + "..."

        minutes_part, seconds_part = "", ""
        if conclusion != "skipped" and started_at and completed_at:
            minutes_part, seconds_part = format_duration(started_at, completed_at)

        prefix = f"X  {name:<{name_column}} {minutes_part:>4} {seconds_part:>3}"
        if len(prefix) + 2 + len(details_url) > width:
            url_separator = "\n   "
        else:
            url_separator = "  "

        print(
            f"{icon}  {name:<{name_column}} {CYAN}{minutes_part:>4} {seconds_part:>3}{RESET}"
            f"{url_separator}{GREY}{details_url}{RESET}"
        )

    return 0 if all_success else 1


if __name__ == "__main__":
    main()
