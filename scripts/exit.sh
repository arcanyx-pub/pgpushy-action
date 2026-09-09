#!/usr/bin/env bash
#
# Fail the action's step with pgpushy's exit code, or, for a destructive plan
# the caller asked to route on, succeed with the outputs already set.
#
# Exit 1 fails the step whatever `on-destructive` says, and that asymmetry is
# the point. `continue-on-error: true` cannot tell a refused plan from a
# destructive one — it swallows both — and spec §9.1 makes 1 and 2 route to
# different people: a broken source tree is the author's problem, a dropped
# column is a reviewer's. An input that turns 2 into a reportable finding while
# leaving 1 fatal keeps that distinction on the step's own outcome.

set -euo pipefail

: "${EXIT_CODE:?}" "${COMMAND:?}"
: "${ON_DESTRUCTIVE:=fail}"

# `plan` is the only command that exits 2 (spec §9.1); the command is checked
# anyway so that a 2 from anywhere else stays a failure.
if [ "$EXIT_CODE" = 2 ] && [ "$COMMAND" = plan ] && [ "$ON_DESTRUCTIVE" = continue ]; then
    echo "pgpushy exited 2: the plan is valid and would destroy something. on-destructive: continue, so this step succeeds; nothing was applied, and 'destructive' is true for the workflow to route on."
    exit 0
fi

exit "$EXIT_CODE"
