#!/usr/bin/env bash
#
# Check the inputs, the working directory and the tools this run needs, before
# anything is downloaded or connected to.
#
# Every rule here is one the CLI would also enforce, but it enforces them one
# run at a time and with its own vocabulary. Saying "env is required for plan"
# in the action's own words, before the binary is fetched, turns a confusing
# clap error at the bottom of a log into the first line of it.

set -euo pipefail

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

# Only for arguments that belong to another command: the message is always
# the same shape, and naming both halves is what makes it actionable.
forbid() {
    local name="$1" value="$2" allowed="$3"
    if [ -n "$value" ]; then
        fail "'$name' applies to $allowed only, not '$COMMAND'"
    fi
}

: "${COMMAND:?}" "${VERSION:=}"
: "${PGPUSHY_ENV:=}" "${CONFIG:=}" "${PLAN_OUT:=}" "${PLAN:=}" "${COMMENT:=}"
: "${ON_DESTRUCTIVE:=}" "${WORKING_DIRECTORY:=.}"
: "${PASSWORD_COMMAND:=}" "${PLAN_PASSWORD_COMMAND:=}"
# Read from the job's environment rather than from an input, the same way
# mask.sh reads them: they are pgpushy's own interface (spec §10.2, §10.4).
: "${PGPASSWORD:=}" "${PGPUSHY_PLAN_PASSWORD:=}"

case "$COMMAND" in
    setup | validate | generate-check | plan | apply) ;;
    "") fail "'command' is required (setup, validate, generate-check, plan, apply)" ;;
    *) fail "unknown command '$COMMAND' (expected setup, validate, generate-check, plan or apply)" ;;
esac

# `version` is declared by this action for one purpose: to be refused here.
# A composite action is never handed an input it does not declare, so dropping
# it from action.yml would leave a workflow's `version:` reaching nothing and
# the run installing a release its author did not choose — the runner warns
# about the unknown input and nothing fails (actions/runner#665).
[ -z "$VERSION" ] ||
    fail "'version' is not an input of this action: it pins one pgpushy release and verifies it against a hash it ships. Remove the 'version: $VERSION' line and pin pgpushy by pinning the action — see 'Upgrading from v1' in the README. The 'pgpushy-version' output reports what was installed."

# --env selects the target and is required for exactly the two commands that
# have one; validate and generate connect to nothing, and the CLI refuses the
# flag there rather than ignoring it (spec §10.2).
case "$COMMAND" in
    plan | apply)
        if [ -z "$PGPUSHY_ENV" ]; then
            fail "'env' is required for '$COMMAND': it names the [env.<name>] block in pgpushy.toml to reconcile against"
        fi
        ;;
    *)
        forbid env "$PGPUSHY_ENV" "the 'plan' and 'apply' commands"
        ;;
esac

# A password is for connecting, and `setup`, `validate` and `generate-check`
# connect to nothing. Minting one for them would run a command — and charge an
# API call, and burn a token's lifetime — for a value nothing would read.
case "$COMMAND" in
    plan | apply) ;;
    *)
        forbid password-command "$PASSWORD_COMMAND" "the 'plan' and 'apply' commands"
        forbid plan-password-command "$PLAN_PASSWORD_COMMAND" "the 'plan' and 'apply' commands"
        ;;
esac

# One source of truth per password. Both set is not a precedence question worth
# answering: whichever one this action picked, the workflow's author believes
# in the other, and a run that connects with a credential nobody chose is worse
# than a run that stops here.
if [ -n "$PASSWORD_COMMAND" ] && [ -n "$PGPASSWORD" ]; then
    fail "'password-command' and PGPASSWORD are both set: the action would have two target passwords and no way to know which one you meant. Keep the input, or keep the environment variable."
fi
if [ -n "$PLAN_PASSWORD_COMMAND" ] && [ -n "$PGPUSHY_PLAN_PASSWORD" ]; then
    fail "'plan-password-command' and PGPUSHY_PLAN_PASSWORD are both set: the action would have two plan-database passwords and no way to know which one you meant. Keep the input, or keep the environment variable."
fi

[ "$COMMAND" = plan ] || forbid plan-out "$PLAN_OUT" "the 'plan' command"
[ "$COMMAND" = apply ] || forbid plan "$PLAN" "the 'apply' command"

if [ "$COMMAND" != plan ] && [ "$COMMENT" = true ]; then
    fail "'comment' applies to the 'plan' command only, not '$COMMAND'"
fi
case "$COMMENT" in
    true | false | "") ;;
    *) fail "'comment' must be true or false, not '$COMMENT'" ;;
esac

# Only exit 2 is routable, and only `plan` produces one (spec §9.1). The
# rejection names `continue` rather than any value, for the same reason
# `comment` above rejects only `true`: the input carries a default, so every
# command sees the default and asking for the default is asking for nothing.
if [ "$COMMAND" != plan ] && [ "$ON_DESTRUCTIVE" = continue ]; then
    fail "'on-destructive' applies to the 'plan' command only, not '$COMMAND': exit 2 is a plan's destructive finding and no other command reports one"
fi
case "$ON_DESTRUCTIVE" in
    fail | continue | "") ;;
    *) fail "'on-destructive' must be fail or continue, not '$ON_DESTRUCTIVE'" ;;
esac

# `setup` runs no pgpushy command, so there is no project for a config to
# select. Accepting it silently would suggest it had done something.
[ "$COMMAND" != setup ] || forbid config "$CONFIG" "the commands that run pgpushy"

# Failing here rather than at `cd` inside run.sh: a mistyped
# working-directory is worth catching before a binary is downloaded for it.
[ -d "$WORKING_DIRECTORY" ] ||
    fail "'working-directory' is not a directory: '$WORKING_DIRECTORY' (relative to the workspace, $PWD)"

# jq and gh are hard dependencies, and both are on every GitHub-hosted runner.
# A self-hosted runner without them should say so here rather than three
# minutes later, in the middle of reading a plan.
if [ "$COMMAND" = plan ]; then
    command -v jq >/dev/null ||
        fail "'jq' is not on PATH; the plan artifact's summary.json is read with it. Hosted runners have it; a self-hosted runner must install it."
    if [ "$COMMENT" = true ]; then
        command -v gh >/dev/null ||
            fail "'gh' is not on PATH; the plan comment is posted with it. Hosted runners have it; a self-hosted runner must install it."
    fi
fi

echo "pgpushy-action: $COMMAND"
