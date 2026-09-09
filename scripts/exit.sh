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

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

: "${COMMAND:?}"
: "${EXIT_CODE:=}" "${ON_DESTRUCTIVE:=fail}"

# `exit` takes its argument modulo 256, so a code this script passes on without
# recognizing it is a code it may silently turn into a success — `exit 256` is
# 0. spec §9.1 contracts three values and the `exit-code` output carries the
# real one whatever happens here, so anything else fails the step by name.
case "$EXIT_CODE" in
    0 | 1 | 2) ;;
    "")
        fail "the run step recorded no exit code; there is nothing to exit with, and a step that guessed at one would be reporting a result nobody produced"
        ;;
    *)
        fail "pgpushy exited '$EXIT_CODE', which is not one of the codes it contracts to return (0, 1 or 2 — spec §9.1); failing the step, and the exit-code output carries what it actually was"
        ;;
esac

# `plan` is the only command that exits 2 (spec §9.1); the command is checked
# anyway so that a 2 from anywhere else stays a failure.
if [ "$EXIT_CODE" = 2 ] && [ "$COMMAND" = plan ] && [ "$ON_DESTRUCTIVE" = continue ]; then
    # A notice, so the finding is an annotation on the run rather than a line
    # in a log nobody opens: this step is about to report success for a plan
    # that would destroy something.
    echo "::notice::pgpushy-action: the plan is valid and would destroy something (pgpushy exited 2). on-destructive: continue, so this step succeeds; nothing was applied, and 'destructive' is true for the workflow to route on."
    exit 0
fi

exit "$EXIT_CODE"
