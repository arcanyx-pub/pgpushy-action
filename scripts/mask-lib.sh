# shellcheck shell=bash
#
# Registering a value with the runner's log masker, for the scripts that have
# one to register.
#
# Sourced rather than run: two steps hand the runner a password — the one that
# masks what the job already had in its environment, and the one that mints a
# password inside the action — and a value is only masked if it was escaped the
# way the runner expects. One function, so those two steps cannot disagree
# about the escaping, the floor, or the line a workflow greps for.

# The runner redacts every occurrence of a masked string anywhere in the log,
# not just the places the secret was meant to appear. A short value therefore
# blacks out unrelated text — a password of `pw` turns every "pw" in a plan
# into `***` — and a reviewer reading a redacted plan is worse off than one
# reading an unmasked short password that should not have been a password.
# Guarded, because a script that sources this file twice would otherwise fail
# on the second assignment to a readonly name.
[ -n "${MIN_LENGTH:-}" ] || readonly MIN_LENGTH=8

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
