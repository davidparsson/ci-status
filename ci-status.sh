#!/usr/bin/env bash
WATCH=0
REVERSE=0
QUIET=0
VERBOSE=0
PORCELAIN=0
GIT_REF_ARGUMENT=""

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [git-ref]

Show GitHub CI check-run statuses for a commit. Defaults to HEAD (or its
upstream tracking commit if the local commit isn't pushed).

By default, passing checks (success, neutral, skipped, in-progress) are
collapsed into one summary line each; only checks that need attention
(cancelled, timed out, failed, action required) are listed in full. Use
--verbose to list every check, or --quiet for summaries only.

Options:
  -w, --watch      Refresh in place every 5s, exiting once all checks complete
  -r, --reverse    Reverse the sort order
  -v, --verbose    List every check in full (no summarizing)
  -q, --quiet      Summarize every status into one line each
  -p, --porcelain  Print a single machine-readable state token and exit
  -h, --help       Show this help and exit
EOF
}

for arg in "$@"; do
    case "$arg" in
        --watch|-w) WATCH=1 ;;
        --reverse|-r) REVERSE=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --quiet|-q) QUIET=1 ;;
        --porcelain|-p) PORCELAIN=1 ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *) GIT_REF_ARGUMENT="$arg" ;;
    esac
done

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

# If no explicit ref was passed and the commit isn't pushed, use upstream instead.
# UPSTREAM_PREFIX flags that fallback for --porcelain output.
UPSTREAM_PREFIX=""
if [[ -z "$GIT_REF_ARGUMENT" ]]; then
    UPSTREAM_COMMIT=$(git rev-parse --verify @{u} 2>/dev/null)
    if [[ -n "$UPSTREAM_COMMIT" && "$COMMIT" != "$UPSTREAM_COMMIT" ]]; then
        if ! git merge-base --is-ancestor "$COMMIT" "$UPSTREAM_COMMIT" 2>/dev/null; then
            COMMIT="$UPSTREAM_COMMIT"
            UPSTREAM_PREFIX="UPSTREAM_"
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

icon_for_conclusion() {
    case "$1" in
        success) echo "${GREEN}✔︎${RESET}" ;;
        failure) echo "${RED}✖︎${RESET}" ;;
        cancelled) echo "${YELLOW}✖︎${RESET}" ;;
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

# Whether checks of the given rank are collapsed into a summary line rather than
# listed individually. --verbose lists everything; --quiet summarizes everything;
# the default summarizes the passing modes (success, neutral, building, skipped).
summarize_rank() {
    (( VERBOSE == 1 )) && return 1
    (( QUIET == 1 )) && return 0
    case "$1" in
        1|2|3|4) return 0 ;;  # success / neutral / building / skipped
        *) return 1 ;;
    esac
}

SORT_ORDER="ascending"
if [[ $REVERSE -eq 1 ]]; then
    SORT_ORDER="descending"
fi

# Fetch check-runs and render one frame. Sets the globals statuses_found,
# all_success and all_completed for the caller to inspect.
render_once() {
    # Call gh api with pagination and collect JSON
    local RAW_JSON gh_exit
    RAW_JSON=$(gh api --paginate "$API_PATH?per_page=100" -H "Accept: application/vnd.github+json" 2> /dev/null)
    gh_exit=$?

    local rows
    rows=$(
        jq -r --slurp --arg order "$SORT_ORDER" '
            # Rank each check best -> worst. Used to sort, and emitted as the
            # first column so the shell can find the worst status without
            # re-deriving the priorities.
            def rank:
                .conclusion
                | (if . == "success" then 1
                   elif . == "neutral" then 2
                   elif . == "skipped" then 4
                   elif . == "cancelled" then 5
                   elif . == "timed_out" then 6
                   elif . == "failure" then 7
                   elif . == "action_required" then 8
                   else 3 end);
            [.[].check_runs // [] | .[]]
            | sort_by(.name) | sort_by(rank)
            | if $order == "descending" then reverse else . end | .[]
            | [
                rank,
                (.status // "unknown"),
                (.conclusion // "pending"),
                (.name // "-"),
                (.details_url // "-"),
                (.started_at | if (. != null) then strptime("%Y-%m-%dT%H:%M:%SZ") | mktime else null end),
                (.completed_at | if (. != null) then strptime("%Y-%m-%dT%H:%M:%SZ") | mktime else null end)
              ] | @tsv
        ' <<< "$RAW_JSON"
    )

    local rank terminal_width status conclusion name details_url started_at completed_at
    local icon first_duration second_duration url_separator total_seconds seconds minutes
    local total_count=0 r count label state line details="" out=""
    local -a seen_ranks=() count_by_rank=() status_by_rank=() concl_by_rank=()
    terminal_width="$(stty size 2>/dev/null | cut -d' ' -f2)"
    statuses_found=0
    all_success=1
    all_completed=1
    while IFS=$'\t' read -r rank status conclusion name details_url started_at completed_at; do
        if [[ "$status" == "" ]]; then
            continue
        fi

        statuses_found=1
        if [[ "$conclusion" != "success" && "$conclusion" != "skipped" ]]; then
            all_success=0
        fi
        if [[ "$status" != "completed" ]]; then
            all_completed=0
        fi

        # Tally each status by the rank jq emitted, recording ranks in the order
        # they first appear (already best -> worst, or reversed with -r) plus a
        # representative status/conclusion per rank for the --quiet summary.
        total_count=$((total_count + 1))
        (( ${count_by_rank[$rank]:-0} == 0 )) && seen_ranks+=("$rank")
        count_by_rank[$rank]=$(( ${count_by_rank[$rank]:-0} + 1 ))
        status_by_rank[$rank]=$status
        concl_by_rank[$rank]=$conclusion

        # Porcelain emits a single token below; summarized ranks are collapsed
        # into the summary block below. Only detailed rows are buffered here, so
        # they can be printed after the summaries.
        [[ $PORCELAIN -eq 1 ]] && continue
        summarize_rank "$rank" && continue

        icon=$(build_icon "$status" "$conclusion")

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
        printf -v line "%s  %-60s ${CYAN}%4s %3s${RESET}${url_separator}${LIGHT_BLACK}%s${RESET}\n" \
            "$icon" "$name" "$first_duration" "$second_duration" "$details_url"
        details+=$line
    done <<< "$rows"

    if [[ $PORCELAIN -eq 1 ]]; then
        # Single machine-readable state token, worst priority first. An
        # UPSTREAM_ prefix marks that the upstream commit was checked.
        if (( gh_exit != 0 )); then
            state=UNAVAILABLE
        elif (( ${count_by_rank[8]:-0} > 0 )); then
            state=ACTION_REQUIRED
        elif (( ${count_by_rank[7]:-0} > 0 )); then
            state=FAILURE
        elif (( ${count_by_rank[5]:-0} > 0 || ${count_by_rank[6]:-0} > 0 )); then
            state=CANCELLED
        elif (( statuses_found == 1 && all_completed == 0 )); then
            state=BUILDING
        elif (( ${count_by_rank[2]:-0} > 0 )); then
            state=NEUTRAL
        elif (( ${count_by_rank[1]:-0} > 0 )); then
            state=SUCCESS
        elif (( ${count_by_rank[4]:-0} > 0 )); then
            state=SKIPPED
        else
            state=UNKNOWN
        fi
        out="${UPSTREAM_PREFIX}${state}"$'\n'
        [[ $statuses_found -eq 0 ]] && all_completed=0
    elif [[ $statuses_found -eq 0 ]]; then
        out="${GREY}No status${RESET}"$'\n'
        all_completed=0
    else
        # A summary line per collapsed status (in jq's order), then the detailed
        # rows buffered above. Which ranks collapse depends on the mode.
        for r in "${seen_ranks[@]}"; do
            summarize_rank "$r" || continue
            count=${count_by_rank[$r]}
            conclusion=${concl_by_rank[$r]}
            case "$conclusion" in
                success) label="passed" ;;
                failure) label="failed" ;;
                timed_out) label="timed out" ;;
                action_required) label="action required" ;;
                *) label="$conclusion" ;;  # neutral / skipped / cancelled / pending / ...
            esac
            icon=$(build_icon "${status_by_rank[$r]}" "$conclusion")
            if (( count == total_count )); then
                printf -v line "%s  All %d checks %s\n" "$icon" "$total_count" "$label"
            else
                printf -v line "%s  %d of %d checks %s\n" "$icon" "$count" "$total_count" "$label"
            fi
            out+=$line
        done
        out+=$details
    fi

    if [[ $WATCH -eq 1 ]]; then
        # Home, then redraw with each line cleared to its end (\033[K) so a
        # shorter line can't leave stragglers from a longer previous frame, and
        # clear any lines below a now-shorter frame (\033[J). Nothing is printed
        # before this point, so the previous frame stays put during the fetch.
        printf '\033[H%s\033[J' "${out//$'\n'/$'\033[K\n'}"
    else
        printf '%s' "$out"
    fi
}

if [[ $WATCH -eq 1 ]]; then
    trap 'exit 0' INT
    while :; do
        render_once
        [[ $all_completed -eq 1 ]] && break
        sleep 5
    done
else
    render_once
fi

# Propagate pass/fail. The watch loop only breaks once every check has completed,
# so this gives the same exit code as a one-shot run.
if [[ $statuses_found -eq 0 || $all_success -eq 0 ]]; then
    exit 1
fi

exit 0
