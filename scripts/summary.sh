#!/usr/bin/env bash
#
# Write the plan to the run's step summary.
#
# Every `plan`, with no input to turn it off. A run on a push or a schedule has
# no pull request to comment on, and its plan is otherwise only in the log,
# which means opening the job and scrolling to find out whether anything was
# going to change. The summary puts the same body on the run's own page.
#
# Nothing here fails the run. The plan is the result and its exit code is
# already recorded as an output; a summary that could not be written is worth a
# warning, not a failed deployment. Hence no `-e`, and a warn-and-succeed path
# on every branch.

set -uo pipefail

warn() {
    echo "::warning::pgpushy-action: $1"
    exit 0
}

: "${GITHUB_STEP_SUMMARY:=}" "${GITHUB_ACTION_PATH:=}"

[ -n "$GITHUB_STEP_SUMMARY" ] ||
    warn "this runner set no \$GITHUB_STEP_SUMMARY, so the plan is in the log only"
[ -n "$GITHUB_ACTION_PATH" ] ||
    warn "\$GITHUB_ACTION_PATH is unset, so the plan body could not be built"

# The same body the pull-request comment carries, minus the hidden marker: the
# marker exists so a comment can be found again and edited, and a step summary
# is never looked up. Appended because that is what the workflow command asks
# for; the file is this step's own and the runner hands it over empty, so there
# is nothing here to append to or to clobber.
#
# It keeps the comment's 60,000-byte truncation too, though a step summary may
# be 1 MiB. One budget is worth more here than the extra room: the summary and
# the comment are the same plan, a reviewer who reads both should not find one
# of them longer, and a plan that overruns 60 KB is one to read in the artifact
# rather than in either. "The same plan" is as far as the claim goes: the
# runner scrubs this file through the secret masker before uploading it, and
# the comment goes out through `gh api` unscrubbed, so a plan that quotes a
# masked value reads `***` here and reads the value there.
if ! WITHOUT_MARKER=1 "$GITHUB_ACTION_PATH/scripts/comment-body.sh" >>"$GITHUB_STEP_SUMMARY"; then
    warn "could not write the plan to the step summary"
fi

echo "wrote the plan for env ${PGPUSHY_ENV:-} to the step summary"
