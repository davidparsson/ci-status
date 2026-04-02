#!/usr/bin/env bash
WATCH=0
REVERSE=0
GIT_REF_ARGUMENT=""
for arg in "$@"; do
    case "$arg" in
        --watch|-w) WATCH=1 ;;
        --reverse|-r) REVERSE=1 ;;
        *) GIT_REF_ARGUMENT="$arg" ;;
    esac
done

if [[ $WATCH -eq 1 ]]; then
    WATCH_ARGS=("-r")
    [[ -n "$GIT_REF_ARGUMENT" ]] && WATCH_ARGS+=("$GIT_REF_ARGUMENT")
    watch --color "$0" "${WATCH_ARGS[@]}"
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

COMMIT=$(git rev-parse --verify ${GIT_REF_ARGUMENT:-HEAD} 2>/dev/null)
if [[ -z "$COMMIT" ]]; then
  echo "No commit specified or detected." >&2
  exit 1
fi

# If no explicit ref was passed and the commit isn't pushed, use upstream instead
if [[ -z "$GIT_REF_ARGUMENT" ]]; then
    UPSTREAM_COMMIT=$(git rev-parse --verify @{u} 2>/dev/null)
    if [[ -n "$UPSTREAM_COMMIT" && "$COMMIT" != "$UPSTREAM_COMMIT" ]]; then
        if ! git merge-base --is-ancestor "$COMMIT" "$UPSTREAM_COMMIT" 2>/dev/null; then
            COMMIT="$UPSTREAM_COMMIT"
        fi
    fi
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
LIGHT_BLACK=$'\033[0;90m'
BOLD=$'\033[1m'

API_PATH="/repos/${REPO}/commits/${COMMIT}/check-runs"

# Call gh api with pagination and collect JSON
RAW_JSON=$(gh api --paginate "$API_PATH?per_page=100" -H "Accept: application/vnd.github+json" 2> /dev/null)

icon_for_conclusion() {
    case "$1" in
        success) echo "${GREEN}✔︎${RESET}" ;;
        failure) echo "${RED}✖︎${RESET}" ;;
        cancelled) echo "${LIGHT_BLACK}✖︎${RESET}" ;;
        neutral) echo "${BLUE}✔︎${RESET}" ;;
        timed_out) echo "${YELLOW}✖︎${RESET}" ;;
        action_required) echo "${YELLOW}⚠${RESET}" ;;
        skipped) echo "${LIGHT_BLACK}—${RESET}" ;;
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

SORT_ORDER="ascending"
if [[ $REVERSE -eq 1 ]]; then
    SORT_ORDER="descending"
fi

rows=$(
    jq -r --slurp --arg order "$SORT_ORDER" '
        [.[].check_runs // [] | .[]]
        | sort_by(.name) | sort_by(
            .conclusion
            | (
                if . == "success" then 1
                elif . == "neutral" then 2
                elif . == "skipped" then 4
                elif . == "cancelled" then 5
                elif . == "timed_out" then 6
                elif . == "failure" then 7
                elif . == "action_required" then 8
                else 3 end
            )
        ) | if $order == "descending" then reverse else . end | .[]
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

terminal_width="$(stty size 2>/dev/null | cut -d' ' -f2)"
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

    # visible prefix: 1 (icon) + 2 + 60 (name) + 4+1+3 (duration) + 2 (space) = 73
    if (( 73 + ${#details_url} > terminal_width )); then
        url_separator="\n   "
    else
        url_separator="  "
    fi
    printf "%s  %-60s ${CYAN}%4s %3s${RESET}${url_separator}${LIGHT_BLACK}%s${RESET}\n" \
        "$build_icon" "$name" "$first_duration" "$second_duration" "$details_url"
done <<< "$rows"

if [[ $statuses_found -eq 0 ]]; then
    echo "${GREY}No status${RESET}"
    exit 1
elif [[ $all_success -eq 0 ]]; then
    exit 1
fi

exit 0
