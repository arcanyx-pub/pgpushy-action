#!/usr/bin/env bash
#
# Run one pgpushy command and record what it did, without ever failing.
#
# The exit code is the whole point of the contract (spec §9.1) — 2 is a valid
# plan that would drop something, and routes to a different person than 1 —
# so it has to reach the caller as an output whatever it is. This script
# therefore always succeeds, writes the code, and leaves failing the step to
# the last step in action.yml. That ordering is not a style choice: outputs
# written by a step that then exits non-zero are not something to bet a
# destructive-change gate on.

set -euo pipefail

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

: "${COMMAND:?}" "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}"
: "${PGPUSHY_ENV:=}" "${CONFIG:=}" "${PLAN_OUT:=}" "${PLAN:=}" "${WORKING_DIRECTORY:=.}"

# `setup` installs and stops. It still reports an exit code, so that a
# workflow reading `exit-code` does not have to care which command ran.
if [ "$COMMAND" = setup ]; then
    echo "exit-code=0" >>"$GITHUB_OUTPUT"
    exit 0
fi

cd "$WORKING_DIRECTORY" || fail "working-directory '$WORKING_DIRECTORY' does not exist"

# Outside the workspace, so a captured plan never lands in the source tree a
# later step might upload or diff.
log="$RUNNER_TEMP/pgpushy-$COMMAND.log"

args=()
case "$COMMAND" in
    validate)
        args=(validate)
        ;;
    generate-check)
        args=(generate --check)
        ;;
    plan)
        # A plan artifact is written even when nobody asked for one: it is
        # where summary.json lives (spec §8.9), and summary.json is what the
        # `destructive` output and the PR comment are read from. Unasked-for
        # artifacts go to the runner's temp directory, so they neither appear
        # in the workspace nor outlive the job.
        plan_dir="${PLAN_OUT:-$RUNNER_TEMP/pgpushy-plan}"
        args=(plan --env "$PGPUSHY_ENV" --plan-out "$plan_dir")
        ;;
    apply)
        # Always --auto-approve. stdin is never a terminal in Actions, so
        # pgpushy would refuse the run outright (spec §8.6), and the approval
        # this shape relies on is not a prompt: it is the required reviewers
        # on the caller's `environment:`, which have already answered by the
        # time this job is allowed to start.
        args=(apply --env "$PGPUSHY_ENV" --auto-approve)
        [ -z "$PLAN" ] || args+=(--plan "$PLAN")
        ;;
    *)
        fail "unknown command '$COMMAND'"
        ;;
esac
[ -z "$CONFIG" ] || args+=(--config "$CONFIG")

echo "+ pgpushy ${args[*]}"

# Streamed to the log so a human watching the run sees the plan as it is
# built, and captured so the PR comment can carry the same text. pgpushy
# suppresses colour when stdout is not a terminal, and a pipe is not one, so
# what lands in the file is already plain.
set +e
pgpushy "${args[@]}" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
set -e

# First, before anything that could itself go wrong.
{
    echo "exit-code=$code"
    echo "log-file=$log"
} >>"$GITHUB_OUTPUT"

if [ "$COMMAND" = plan ]; then
    # Absolute from here on: the paths a consumer gives are relative to
    # working-directory, and the comment script runs from somewhere else.
    plan_dir=$(cd "$plan_dir" 2>/dev/null && pwd || true)
    summary="${plan_dir:+$plan_dir/summary.json}"

    # A refused plan writes no artifact (spec §8.9) — a cycle cannot be
    # re-detected without the source tree, so pgpushy never mints one — and
    # nothing was classified as destructive because nothing got that far.
    if [ -n "$summary" ] && [ -f "$summary" ]; then
        destructive_count=$(jq -r '.total.destructive' "$summary")
    else
        destructive_count=0
    fi

    # Exit 2 *is* the destructive finding (spec §9.1), so it counts even in
    # the impossible case of an artifact that says otherwise.
    if [ "$code" = 2 ] || [ "$destructive_count" -gt 0 ]; then
        destructive=true
    else
        destructive=false
    fi

    {
        echo "destructive=$destructive"
        echo "plan-dir=$plan_dir"
    } >>"$GITHUB_OUTPUT"
    echo "pgpushy exited $code; destructive=$destructive"
else
    echo "pgpushy exited $code"
fi
