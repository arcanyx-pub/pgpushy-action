#!/usr/bin/env bash
#
# Build the pull-request comment body for a plan run and print it on stdout.
#
# Separate from the script that posts it so the interesting half — which
# headline an exit code earns, what summary.json says, where the truncation
# falls — can be run and read without a pull request or a token.

set -euo pipefail

: "${PGPUSHY_ENV:?}" "${EXIT_CODE:?}"
: "${LOG_FILE:=}" "${PLAN_DIR:=}"

# GitHub rejects an issue comment body over 65,536 bytes. Stopping well short
# leaves room for the headline and the destructive list, which are the parts
# worth keeping when the plan itself is enormous.
readonly MAX_BODY=60000

plural() {
    if [ "$1" = 1 ]; then printf '%s' "$2"; else printf '%s' "${3:-$2s}"; fi
}

summary="${PLAN_DIR:+$PLAN_DIR/summary.json}"
have_summary=false
if [ -n "$summary" ] && [ -f "$summary" ]; then
    have_summary=true
fi

marker="<!-- pgpushy-action plan env=$PGPUSHY_ENV -->"

total_steps=0
changed_schemas=0
destructive_count=0
if $have_summary; then
    total_steps=$(jq -r '.total.steps' "$summary")
    destructive_count=$(jq -r '.total.destructive' "$summary")
    changed_schemas=$(jq -r '[.schemas[] | select(.steps > 0)] | length' "$summary")
fi

case "$EXIT_CODE" in
    0)
        if [ "$total_steps" -eq 0 ]; then
            headline="No schema changes for \`$PGPUSHY_ENV\`"
        else
            headline="$total_steps $(plural "$total_steps" step) across $changed_schemas $(plural "$changed_schemas" schema schemas) for \`$PGPUSHY_ENV\`"
        fi
        ;;
    2)
        headline="⚠️ Destructive changes for \`$PGPUSHY_ENV\` (blocked: \`allow_destructive\` is not set for this environment)"
        ;;
    1)
        headline="pgpushy refused the plan for \`$PGPUSHY_ENV\`"
        ;;
    *)
        headline="pgpushy exited $EXIT_CODE for \`$PGPUSHY_ENV\`"
        ;;
esac

# The destructive steps are listed whenever there are any, not only on exit 2:
# an environment with `allow_destructive = true` plans to 0 and still drops
# things, and that is exactly what a reviewer is here to see.
destructive_list=""
if $have_summary && [ "$destructive_count" -gt 0 ]; then
    destructive_list=$(jq -r '
        "**Destructive steps (\(.total.destructive)):**\n",
        (.destructive[] | "- `\(.kind)` — `\(.path)`")
    ' "$summary")
    if [ "$EXIT_CODE" = 0 ]; then
        destructive_list="This environment sets \`allow_destructive = true\`, so the plan is not blocked.

$destructive_list"
    fi
fi

run_url=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_url="[Workflow run]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)"
fi

log=""
if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    log=$(cat "$LOG_FILE")
else
    log="(pgpushy produced no output)"
fi

emit() {
    printf '%s\n\n' "$marker"
    printf '### %s\n' "$headline"
    [ -z "$destructive_list" ] || printf '\n%s\n' "$destructive_list"
    printf '\n<details><summary><code>pgpushy plan</code> output</summary>\n\n'
    # The backticks are a markdown fence, not a substitution.
    # shellcheck disable=SC2016
    printf '```text\n%s\n```\n\n</details>\n' "$1"
    [ -z "$run_url" ] || printf '\n%s\n' "$run_url"
}

body=$(emit "$log")

# Truncate the plan output rather than the headline: the fixed parts are
# measured first, and whatever is left is what the log may occupy. Bytes, not
# characters, because that is the unit GitHub's limit is in. The head is kept
# because a plan reads from the top, and the note says what was lost so nobody
# mistakes a cut-off plan for a short one.
bytes_of() { printf '%s' "$1" | wc -c; }

if [ "$(bytes_of "$body")" -gt "$MAX_BODY" ]; then
    note=$'\n\n... truncated: this plan is too large for a GitHub comment. See the workflow run log for all of it.'
    fixed=$(($(bytes_of "$body") - $(bytes_of "$log")))
    budget=$((MAX_BODY - fixed - $(bytes_of "$note")))
    [ "$budget" -gt 0 ] || budget=0
    body=$(emit "$(printf '%s' "$log" | head -c "$budget")$note")
fi

printf '%s\n' "$body"
