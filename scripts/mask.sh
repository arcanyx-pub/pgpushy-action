#!/usr/bin/env bash
#
# Register the database passwords with the runner's log masker, for the rest
# of the job.
#
# pgpushy reads two passwords from the environment and nothing else: PGPASSWORD
# for the target, and PGPUSHY_PLAN_PASSWORD for an external plan database, which
# is a separate server with separate credentials (spec §10.4). A secret that
# came from `secrets.*` is masked already; one minted during the run — a token
# from an OIDC exchange, an RDS auth token, anything a job computed rather than
# stored — is not, because no secret store ever saw it. Masking here covers both
# without the caller having to know which kind it has.
#
# This runs early, before the binary is fetched and before anything connects,
# so that everything the action itself logs is already covered.

set -euo pipefail

: "${PGPASSWORD:=}" "${PGPUSHY_PLAN_PASSWORD:=}"

# The runner redacts every occurrence of a masked string anywhere in the log,
# not just the places the secret was meant to appear. A short value therefore
# blacks out unrelated text — a password of `pw` turns every "pw" in a plan
# into `***` — and a reviewer reading a redacted plan is worse off than one
# reading an unmasked short password that should not have been a password.
readonly MIN_LENGTH=8

mask() {
    local name="$1" value="$2" escaped

    [ -n "$value" ] || return 0

    if [ "${#value}" -lt "$MIN_LENGTH" ]; then
        echo "::warning::pgpushy-action: $name is under $MIN_LENGTH characters, so it is not masked: the runner redacts every occurrence of a masked string, and a short one would black out unrelated text in this job's log"
        return 0
    fi

    # The runner un-escapes a workflow command's data before the masker ever
    # sees it: `%25` becomes a percent sign, `%0A` a newline, `%0D` a carriage
    # return. So a password that literally contains `%25` — minted tokens are
    # routinely percent-encoded — would register a *different* string than the
    # one in the environment, and the real password would go on appearing in
    # the log while the action reported it masked. Escaping is what makes the
    # registered value the value; it is exactly what `@actions/core` does, and
    # the percent has to go first or the escapes added below would themselves
    # be escaped.
    #
    # It also settles the multi-line case, without a rule of our own: a value
    # carrying newlines arrives at the runner whole, and the runner registers
    # each of its lines. The floor above is measured on the value, so a
    # multi-line password with one short line still gets that line masked.
    escaped=${value//%/%25}
    escaped=${escaped//$'\r'/%0D}
    escaped=${escaped//$'\n'/%0A}

    # The only line that carries the value. The runner consumes this command
    # and prints the value back as `***`, which is the whole mechanism.
    echo "::add-mask::$escaped"
    # Named, never echoed: a fixed string, so a workflow can confirm the
    # masking happened without the log carrying the secret to confirm it with.
    echo "pgpushy-action: masked $name"
}

mask PGPASSWORD "$PGPASSWORD"
mask PGPUSHY_PLAN_PASSWORD "$PGPUSHY_PLAN_PASSWORD"
