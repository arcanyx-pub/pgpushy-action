#!/usr/bin/env bash
#
# Mint one database password inside the action, mask it, and leave it where the
# step that runs pgpushy can pick it up.
#
# A password that came from `secrets.*` is masked before the job starts. One
# minted during the run — an RDS IAM auth token, an OIDC exchange, anything a
# step computed rather than stored — has never been through a secret store, so
# nothing masks it, and this action's own mask step runs *after* the step that
# would have minted it. Minting here closes both halves: the value is handed to
# the log masker before anything else can log it, and it never goes into
# GITHUB_ENV, which would carry it to every later step and third-party action
# in the job.
#
# The command is the workflow author's own text, run with the job's
# environment — the same trust level as a `run:` step in the same workflow, and
# no more. It is not a place to put anything that came out of a pull request;
# see "Never use this with pull_request_target" in the README.
#
# One password per invocation: the action calls this once for the target and
# once for an external plan database (spec §10.4), which are two commands
# minting two credentials for two servers.

set -euo pipefail

# shellcheck source=scripts/mask-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/mask-lib.sh"

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

# INPUT_NAME is what a failure names, because the workflow author knows this
# command by the input they wrote it in. VAR_NAME is the variable pgpushy will
# read it from, and is what the mask confirmation line reports.
: "${INPUT_NAME:?}" "${VAR_NAME:?}" "${MINT_COMMAND:?}" "${PASSWORD_FILE:?}"
: "${WORKING_DIRECTORY:=.}"

# A mint is one API call. Sixty seconds is not a budget for slow credentials,
# it is a ceiling on a command that will never return — a prompt on a terminal
# that is not there, a network call with no timeout of its own — which would
# otherwise hold the runner for the job's whole limit. The fixture check
# overrides it to keep the timeout case fast; the name is scoped so that a
# variable in the job's environment cannot change it by accident.
: "${PGPUSHY_ACTION_MINT_TIMEOUT:=60}"

# Everything this script creates holds a password: 0600 from the moment it
# exists, rather than created and then chmod-ed.
umask 077

cd "$WORKING_DIRECTORY" ||
    fail "'working-directory' is not a directory: '$WORKING_DIRECTORY'"

# A file left behind by an earlier run of the action in this job must never be
# read as this run's password. Removed before the command runs, so there is no
# window where a stale value would satisfy the step that reads it.
rm -f "$PASSWORD_FILE"

raw=$(mktemp "$PASSWORD_FILE.XXXXXX")
expired="$raw.expired"
trap 'rm -f "$raw" "$expired"' EXIT

# Named, never echoed with its text. The command is the workflow's own source,
# but a command line is where a credential gets typed by accident, and the
# action gains nothing by printing it: what a failing mint needs is its own
# stderr, which passes through untouched.
echo "pgpushy-action: minting $VAR_NAME with '$INPUT_NAME'"

# GNU coreutils' timeout is on every Linux runner and on no macOS one, where a
# Homebrew coreutils installs it as gtimeout. The bash watchdog below covers a
# runner with neither, so the ceiling is a property of this action rather than
# of the image it happens to run on.
timeout_bin=""
for candidate in timeout gtimeout; do
    if command -v "$candidate" >/dev/null 2>&1; then
        timeout_bin=$candidate
        break
    fi
done

# --noprofile --norc so the command means the same thing on every runner
# regardless of what the image's shell startup files do; -e and -o pipefail so
# that `aws … | jq …` failing halfway is a failed mint rather than an empty
# password. stdout is captured — it is the password — and stderr is left
# alone, because that is where a minting CLI puts the error a human needs.
status=0
timed_out=no
if [ -n "$timeout_bin" ]; then
    "$timeout_bin" --kill-after=5 "$PGPUSHY_ACTION_MINT_TIMEOUT" \
        bash --noprofile --norc -eo pipefail -c "$MINT_COMMAND" >"$raw" || status=$?
    [ "$status" != 124 ] || timed_out=yes
else
    bash --noprofile --norc -eo pipefail -c "$MINT_COMMAND" >"$raw" &
    minter=$!
    # The marker file, and not the exit status, is what says the deadline was
    # the reason: a command killed by something else also dies of a signal, and
    # reporting that as a timeout would send its author looking at the wrong
    # thing.
    (
        sleep "$PGPUSHY_ACTION_MINT_TIMEOUT"
        : >"$expired"
        kill -TERM "$minter" 2>/dev/null
        sleep 5
        kill -KILL "$minter" 2>/dev/null
    ) &
    watchdog=$!
    wait "$minter" || status=$?
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    [ ! -e "$expired" ] || timed_out=yes
fi

if [ "$timed_out" = yes ]; then
    fail "'$INPUT_NAME' did not produce a password within ${PGPUSHY_ACTION_MINT_TIMEOUT}s and was killed. Minting a credential is one call; a command that waits on anything else waits here, holding the runner."
fi
if [ "$status" != 0 ]; then
    # Its stderr is already in the log above. What it wrote to stdout is not,
    # and must not be: on a command that failed *after* printing, stdout is
    # still the password.
    fail "'$INPUT_NAME' exited $status. Its own error output is above; what it wrote to standard output is not shown, because that is where the password would be."
fi

# Command substitution strips *every* trailing newline, and the contract is to
# strip exactly one: `printf 'tok\n'` is an ordinary minting CLI and
# `printf 'tok\n\n'` is not a password this action will guess about. The
# sentinel character is what makes the difference visible, and is removed
# before anything looks at the value.
value=$(
    cat "$raw"
    echo x
)
value=${value%x}
value=${value%$'\n'}

[ -n "$value" ] ||
    fail "'$INPUT_NAME' produced an empty password. A command that prints nothing has not failed loudly enough to be a mint: check its own error output above."
case "$value" in
    *$'\n'*)
        fail "'$INPUT_NAME' produced a password containing a newline. pgpushy reads $VAR_NAME from the environment, which a multi-line value does not survive cleanly, so it is refused rather than truncated. The value is not shown."
        ;;
esac

# Before the value is anywhere but this process: from here on it is on disk,
# and the next thing that reads it is a step that logs.
mask "$VAR_NAME" "$value"

# A composite action's step cannot export an environment variable to a sibling
# step except through GITHUB_ENV, and GITHUB_ENV is exactly the persistence
# this input exists to avoid: it applies to every later step in the job,
# including third-party actions the workflow did not write. So the value goes
# to a file only this run's user can read, the step that runs pgpushy reads it
# into its own environment and deletes it, and the action deletes it again at
# the end whatever the outcome. GITHUB_OUTPUT is no better than GITHUB_ENV
# here: an output is readable by every later step too, and a `${{ }}` reference
# to it would put the value in a `run:` body.
printf '%s' "$value" >"$PASSWORD_FILE"
