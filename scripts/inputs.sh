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

: "${COMMAND:?}" "${VERSION:?}"
: "${PGPUSHY_ENV:=}" "${CONFIG:=}" "${PLAN_OUT:=}" "${PLAN:=}" "${COMMENT:=}"
: "${WORKING_DIRECTORY:=.}"

case "$COMMAND" in
    setup | validate | generate-check | plan | apply) ;;
    "") fail "'command' is required (setup, validate, generate-check, plan, apply)" ;;
    *) fail "unknown command '$COMMAND' (expected setup, validate, generate-check, plan or apply)" ;;
esac

# No "latest". A schema tool that changed under a repository between two runs
# of the same workflow would make a plan and its apply different programs, and
# the version is the cheapest thing in this file to pin.
case "$VERSION" in
    "") fail "'version' is required, e.g. version: 0.3.2" ;;
    latest | LATEST)
        fail "'version' must name a release, e.g. 0.3.2 — there is no 'latest', because a schema tool should not change under a repository between runs"
        ;;
esac
if ! [[ "${VERSION#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    fail "'version' is not a pgpushy release version: '$VERSION' (expected e.g. 0.3.2 or v0.3.2)"
fi

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

[ "$COMMAND" = plan ] || forbid plan-out "$PLAN_OUT" "the 'plan' command"
[ "$COMMAND" = apply ] || forbid plan "$PLAN" "the 'apply' command"

if [ "$COMMAND" != plan ] && [ "$COMMENT" = true ]; then
    fail "'comment' applies to the 'plan' command only, not '$COMMAND'"
fi
case "$COMMENT" in
    true | false | "") ;;
    *) fail "'comment' must be true or false, not '$COMMENT'" ;;
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

echo "pgpushy-action: $COMMAND, pgpushy ${VERSION#v}"
