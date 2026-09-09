#!/usr/bin/env bash
#
# Build the pull-request comment body for a plan run and print it on stdout.
#
# Separate from the script that posts it so the interesting half — which
# headline an exit code earns, what summary.json says, where the truncation
# falls, what a hostile plan can and cannot make this say — can be run and
# read without a pull request or a token.
#
# Everything quoted here is attacker-controlled. pgpushy echoes the DDL it is
# given, and object names and comment literals come from the branch under
# review, so a plan can contain backticks, control characters and Markdown
# that would otherwise close the code fence and continue in the action's own
# voice. The fence is therefore sized to the content rather than assumed, and
# nothing from a plan is ever rendered outside one.

set -euo pipefail

: "${PGPUSHY_ENV:?}" "${EXIT_CODE:?}"
: "${LOG_FILE:=}" "${PLAN_DIR:=}"

# The step summary wants this body without the hidden marker, which is there to
# find a comment again and edit it — a summary is written once and never looked
# up. The marker is dropped at the end rather than never added, so that both
# spellings are the same body under the same budget: the marker-less one is the
# comment minus its first line, byte for byte.
: "${WITHOUT_MARKER:=}"

# GitHub rejects an issue comment body over 65,536 characters. This budget is
# in bytes, which is the conservative reading of that limit and the one `wc -c`
# can enforce, and it stops well short so that the headline and the destructive
# list survive a plan that is enormous.
readonly MAX_BODY=60000

# At most this many destructive steps are listed. A plan that drops a thousand
# columns needs a reviewer to look at the plan, not a comment containing it.
readonly MAX_DESTRUCTIVE=50

bytes_of() { printf '%s' "$1" | wc -c; }

# Everything outside a fence is written by this script, so the only text that
# reaches it from a plan is an environment name — which comes from the
# workflow file, and on a pull request that is a file the pull request may
# have edited.
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177`<>'; }

# Control characters are stripped from fenced content too: tab and newline
# carry meaning in a plan, and the rest are invisible in a diff and can
# reorder what a reviewer reads (U+202E has an ASCII-era cousin in every
# terminal that honours ESC).
strip_control() { tr -d '\000-\010\013-\037\177'; }

# A fence has to be longer than the longest run of backticks it encloses, or
# the content closes it. Three is the minimum a fence may be.
fence_for() {
    local longest
    longest=$(awk '
        {
            line = $0
            while (match(line, /`+/)) {
                if (RLENGTH > m) m = RLENGTH
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { print m + 0 }
    ' <<<"$1")
    local width=$((longest + 1))
    [ "$width" -ge 3 ] || width=3
    printf '%*s' "$width" '' | tr ' ' '`'
}

env_display=$(sanitize "$PGPUSHY_ENV")
marker="<!-- pgpushy-action plan env=$env_display -->"

summary="${PLAN_DIR:+$PLAN_DIR/summary.json}"
have_summary=false
if [ -n "$summary" ] && [ -f "$summary" ]; then
    have_summary=true
fi

plural() {
    if [ "$1" = 1 ]; then printf '%s' "$2"; else printf '%ss' "$2"; fi
}

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
            headline="No schema changes for \`$env_display\`"
        else
            headline="$total_steps $(plural "$total_steps" step) across $changed_schemas $(plural "$changed_schemas" schema) for \`$env_display\`"
        fi
        ;;
    2)
        headline="⚠️ Destructive changes for \`$env_display\` (blocked: \`allow_destructive\` is not set for this environment)"
        ;;
    1)
        headline="pgpushy refused the plan for \`$env_display\`"
        ;;
    *)
        headline="pgpushy exited $EXIT_CODE for \`$env_display\`"
        ;;
esac

# The destructive steps are listed whenever there are any, not only on exit 2:
# an environment with `allow_destructive = true` plans to 0 and still drops
# things, and that is exactly what a reviewer is here to see. They are object
# names, so they go inside a fence like everything else from the plan.
destructive_lines=""
destructive_note=""
if $have_summary && [ "$destructive_count" -gt 0 ]; then
    destructive_lines=$(
        jq -r --argjson limit "$MAX_DESTRUCTIVE" \
            '.destructive[:$limit][] | "\(.kind)\t\(.path)"' "$summary" | strip_control
    )
    if [ "$destructive_count" -gt "$MAX_DESTRUCTIVE" ]; then
        destructive_lines="$destructive_lines
... and $((destructive_count - MAX_DESTRUCTIVE)) more; see the plan artifact"
    fi
    if [ "$EXIT_CODE" = 0 ]; then
        destructive_note="This environment sets \`allow_destructive = true\`, so the plan is not blocked."
    fi
fi

if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    log=$(strip_control <"$LOG_FILE")
else
    log="(pgpushy produced no output)"
fi

run_url=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_url="[Workflow run]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)"
fi

# One fence width for the whole comment, computed over everything a plan
# contributed, so the two blocks cannot disagree.
fence=$(fence_for "$log
$destructive_lines")

emit() {
    printf '%s\n\n' "$marker"
    printf '### %s\n' "$headline"
    [ -z "$destructive_note" ] || printf '\n%s\n' "$destructive_note"
    if [ -n "$destructive_lines" ]; then
        printf '\n**Destructive %s (%s):**\n\n' "$(plural "$destructive_count" step)" "$destructive_count"
        printf '%s\n%s\n%s\n' "$fence" "$destructive_lines" "$fence"
    fi
    printf '\n<details><summary><code>pgpushy plan</code> output</summary>\n\n'
    printf '%s\n%s\n%s\n\n</details>\n' "$fence" "$1" "$fence"
    [ -z "$run_url" ] || printf '\n%s\n' "$run_url"
}

body=$(emit "$log")

# Truncate the plan output rather than the headline: the fixed parts are
# measured first, and whatever is left is what the log may occupy. The head is
# kept because a plan reads from the top, and the note says what was lost so
# nobody mistakes a cut-off plan for a short one.
if [ "$(bytes_of "$body")" -gt "$MAX_BODY" ]; then
    note=$'\n\n... truncated: this plan is too large for a GitHub comment. See the workflow run log for all of it.'
    budget=$((MAX_BODY - ($(bytes_of "$body") - $(bytes_of "$log")) - $(bytes_of "$note")))
    [ "$budget" -gt 0 ] || budget=0
    body=$(emit "$(head -c "$budget" <<<"$log")$note")
fi

# Last resort. The fixed parts are bounded — a capped destructive list, a
# headline, a URL — but "bounded" is not "small enough", and a body GitHub
# rejects with a 422 fails the step over a comment. Cutting here can land
# inside the fence, so one is closed behind it.
if [ "$(bytes_of "$body")" -gt "$MAX_BODY" ]; then
    tail_note=$(printf '\n%s\n\n... truncated: this comment did not fit. See the workflow run log.\n' "$fence")
    body=$(head -c $((MAX_BODY - $(bytes_of "$tail_note"))) <<<"$body")$tail_note
fi

if [ "$WITHOUT_MARKER" = 1 ]; then
    # Everything up to and including the first newline, which is the marker
    # line and nothing else.
    body=${body#*$'\n'}
fi

printf '%s\n' "$body"
