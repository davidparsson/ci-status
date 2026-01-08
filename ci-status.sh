#!/usr/bin/env bash
if [[ "$1" == "--watch" || "$1" == "-w" ]]; then
    watch --color "$0"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh (GitHub CLI) is required. Install from https://cli.github.com/" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install with your package manager." >&2
  exit 1
fi

# Determine repo (owner/repo) from gh or git
REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)"
if [[ -z "$REPO" ]]; then
    echo "Could not determine repository. Ensure you're in a git repo." >&2
    exit 1
fi

COMMIT=${1:-}
if [[ -z "$COMMIT" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "No commit specified and git not available to detect HEAD." >&2
    exit 1
  fi
  COMMIT=$(git rev-parse --verify HEAD)
fi

RESET=$'\033[0m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
GREY=$'\033[0;30m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BLACK=$'\033[0;90m'
BOLD=$'\033[1m'

API_PATH="/repos/${REPO}/commits/${COMMIT}/check-runs"

# Call gh api with pagination and collect JSON
RAW_JSON=$(gh api --paginate "$API_PATH" -H "Accept: application/vnd.github+json" 2> /dev/null)
if [[ $(echo "$RAW_JSON" | jq -r '.status') == "422" ]]; then
    UPSTREAM_COMMIT=$(git rev-parse --verify @{u} 2> /dev/null)
    if [[ -z "$UPSTREAM_COMMIT" ]]; then
        echo "${GREY}No status${RESET}"
        exit 1
    fi
    API_PATH="/repos/${REPO}/commits/${UPSTREAM_COMMIT}/check-runs"
    RAW_JSON=$(gh api --paginate "$API_PATH" -H "Accept: application/vnd.github+json" 2> /dev/null)
fi

icon_for_conclusion() {
    case "$1" in
        success) echo "${GREEN}✔︎️${RESET}" ;;
        failure) echo "${RED}✖︎${RESET}" ;;
        cancelled) echo "${GREY}✖︎${RESET}" ;;
        neutral) echo "${BLUE}✔︎️${RESET}" ;;
        timed_out) echo "${YELLOW}✖︎${RESET}" ;;
        action_required) echo "${YELLOW}⚠${RESET}" ;;
        skipped) echo "${GREY}—${RESET}" ;;
        *) echo "${YELLOW}—${RESET}" ;;
    esac
}

build_icon(){
    status=$1
    conclusion=$2
    case "$status" in
        completed) icon_for_conclusion $conclusion ;;
        *) echo "${YELLOW}•${RESET}" ;;
    esac
}

rows=$(
    jq -r '
        .check_runs
        | sort_by(.name) | sort_by(
            .conclusion
            | (
                if . == "success" then 1
                elif . == "neutral" then 2
                elif . == "skipped" then 3
                elif . == "cancelled" then 4
                elif . == "timed_out" then 5
                elif . == "failure" then 6
                elif . == "action_required" then 7
                else 8 end
            )
        ) []
        | [
            (.status // "unknown"),
            (.conclusion // "pending"),
            (.name // "-"),
            (.details_url // "-"),
            (.started_at | if (. != null) then strptime("%Y-%m-%dT%H:%M:%SZ") | mktime else null end),
            (.completed_at | if (. != null) then strptime("%Y-%m-%dT%H:%M:%SZ") | mktime else null end)
          ] | @tsv
    ' <<< "$RAW_JSON"
)

statuses_found=0
all_success=1
while IFS=$'\t' read -r status conclusion name details_url started_at completed_at; do
    if [[ "$status" == "" ]]; then
        continue
    fi

    statuses_found=1
    if [[ "$conclusion" != "success" && "$conclusion" != "skipped" ]]; then
        all_success=0
    fi
    build_icon=$(build_icon "$status" "$conclusion")

    if [ "${#name}" -gt 60 ]; then
        name="${name:0:57}..."
    fi

    first_duration=""
    second_duration=""
    if [[ "$conclusion" != "skipped" && -n "$started_at" && -n "$completed_at" ]]; then
        total_seconds=$((completed_at - started_at))

        seconds=$((total_seconds % 60))
        second_duration="${seconds}s"

        if ((total_seconds >= 60)); then
            minutes=$((total_seconds / 60))
            first_duration="${minutes}m"
        fi
    fi

    printf "%s  %-60s ${CYAN}%4s %3s${RESET}  ${GREY}%s${RESET}\n" \
        "$build_icon" "$name" "$first_duration" "$second_duration" "$details_url"
done <<< "$rows"

if [[ $statuses_found -eq 0 ]]; then
    echo "${GREY}No status${RESET}"
    exit 1
elif [[ $all_success -eq 0 ]]; then
    exit 1
fi

exit 0
