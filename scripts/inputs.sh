#!/usr/bin/env bash
#
# Check the input combination before anything is downloaded or connected to.
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
: "${PGPUSHY_ENV:=}" "${PLAN_OUT:=}" "${PLAN:=}" "${COMMENT:=}"

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

echo "pgpushy-action: $COMMAND, pgpushy ${VERSION#v}"
