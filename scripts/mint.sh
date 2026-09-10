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
# What this script cannot cover is the command printing the password itself:
# standard error goes to the log unmasked, because at that moment nothing is
# masked yet. A minter run with a debug or verbose flag can therefore put the
# credential in the log in full, permanently.
#
# One password per invocation: the action calls this once for the target and
# once for an external plan database (spec §10.4), which are two commands
# minting two credentials for two servers.

# Before anything expands a value. An earlier step, or any earlier action, can
# put SHELLOPTS=xtrace into the job's environment through GITHUB_ENV, and a
# bash that starts with tracing on traces every expansion to standard error —
# which is the log, at a point where nothing is masked yet. SHELLOPTS is
# readonly and cannot be unset, but it is also dynamic and exported: `set +x`
# takes xtrace out of it, and out of the copy the minting command inherits
# (verified). BASH_XTRACEFD is the other half of the same switch, choosing
# where a trace is written.
set +x
unset BASH_XTRACEFD 2>/dev/null || true

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
# exists, rather than created and then chmod-ed. The minting command inherits
# it, so a CLI that caches a token beside its config writes that 0600 too.
umask 077

cd "$WORKING_DIRECTORY" ||
    fail "'working-directory' is not a directory: '$WORKING_DIRECTORY'"

# A file left behind by an earlier run of the action in this job must never be
# read as this run's password. Removed before the command runs, so there is no
# window where a stale value would satisfy the step that reads it. The glob
# takes the scratch file below with it, including one left by a previous run
# that was killed before its own trap could fire.
rm -f "$PASSWORD_FILE" "$PASSWORD_FILE".*

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
    # 124 is the deadline; 137 is the command being killed five seconds later
    # because it ignored the first signal. A command that chose to exit 124 or
    # 137 by itself is reported as a timeout, which is the price of reading a
    # status rather than a marker — and either way the mint did not produce a
    # password.
    case "$status" in
        124 | 137) timed_out=yes ;;
    esac
else
    # Job control, so the command runs in a process group of its own and a
    # signal to that group reaches whatever it started. Without it a minter
    # that backgrounds something outlives its own timeout, which is what GNU
    # timeout does for us above.
    set -m
    bash --noprofile --norc -eo pipefail -c "$MINT_COMMAND" >"$raw" &
    minter=$!
    # The marker file, and not the exit status, is what says the deadline was
    # the reason: a command killed by something else also dies of a signal, and
    # reporting that as a timeout would send its author looking at the wrong
    # thing.
    (
        sleep "$PGPUSHY_ACTION_MINT_TIMEOUT"
        : >"$expired"
        kill -TERM -"$minter" 2>/dev/null || kill -TERM "$minter" 2>/dev/null
        sleep 5
        kill -KILL -"$minter" 2>/dev/null || kill -KILL "$minter" 2>/dev/null
    ) &
    watchdog=$!
    set +m
    # The redirection is the shell's own "Killed" job notification, which says
    # nothing a human needs and nothing the command printed. The minting
    # command's stderr was connected when it was forked and is untouched by it.
    { wait "$minter" || status=$?; } 2>/dev/null
    # The group again, so the watchdog's sleep goes with it rather than being
    # orphaned for the rest of the timeout.
    kill -TERM -"$watchdog" 2>/dev/null || kill -TERM "$watchdog" 2>/dev/null || true
    { wait "$watchdog" || true; } 2>/dev/null
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

# Bash drops a NUL from a command substitution and carries on, so reading the
# output below would silently produce a *different* password than the command
# printed. Refused instead: this script never guesses at what was meant.
if [ "$(wc -c <"$raw")" -ne "$(tr -d '\0' <"$raw" | wc -c)" ]; then
    fail "'$INPUT_NAME' produced output containing a NUL byte, which is not a password this action will guess at. The value is not shown."
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

# Whitespace inside the value is kept, including at the ends: the runner
# registers the data of an `::add-mask::` command as it arrives, without
# trimming it (actions/runner, AddMaskCommandExtension.ProcessCommand in
# src/Runner.Worker/ActionCommandManager.cs, which passes command.Data to
# SecretMasker.AddValue unchanged), so what gets masked is what pgpushy will
# use. A value that is *nothing but* whitespace is the exception the same
# method makes — IsNullOrWhiteSpace, warn, register nothing — and is refused
# here with the empty case, because it would go into the log unmasked.
if [ -z "${value//[[:space:]]/}" ]; then
    fail "'$INPUT_NAME' produced an empty password (or nothing but whitespace, which the runner declines to mask at all). A command that prints nothing has not failed loudly enough to be a mint: check its own error output above."
fi

line_break=""
case "$value" in
    *$'\r'*) line_break="a carriage return" ;;
    *$'\n'*) line_break="a newline" ;;
esac
if [ -n "$line_break" ]; then
    # The carriage return is the one a CRLF minter leaves behind once the
    # trailing newline is stripped. Refused rather than trimmed, for the same
    # reason as the second newline: pgpushy reads this variable from the
    # environment, where a stray control character is part of the password, and
    # quietly repairing one would mean connecting with something the command
    # did not print.
    fail "'$INPUT_NAME' produced a password containing $line_break. pgpushy reads $VAR_NAME from the environment, which such a value does not survive cleanly, so it is refused rather than trimmed. The value is not shown."
fi

# The masker's floor, applied here as a refusal rather than as a warning. For a
# password that was already in the job's environment, not masking a short value
# is the lesser harm — see mask-lib.sh. For a minted one it is a symptom: no
# credential API returns eight characters, so a short result is an error string
# or a truncated read, and connecting with it would fail anyway, in the log,
# unmasked.
if [ "${#value}" -lt "$MIN_LENGTH" ]; then
    fail "'$INPUT_NAME' produced a password shorter than $MIN_LENGTH characters, which no credential API mints and which the runner's log masker will not register. Treat it as a failed mint: check the command's own error output above. The value is not shown."
fi

# Before the value is anywhere but this process: from here on it is on disk,
# and the next thing that reads it is a step that logs.
mask "$VAR_NAME" "$value"

# A composite action's step cannot export an environment variable to a sibling
# step except through GITHUB_ENV, and GITHUB_ENV is exactly the persistence
# this input exists to avoid: it applies to every step after the action,
# including third-party actions the workflow did not write. So the value goes
# to a file only this run's user can read, the step that runs pgpushy reads it
# into its own environment and deletes it, and the action deletes it again at
# the end whatever the outcome. GITHUB_OUTPUT is no better than GITHUB_ENV
# here: an output is readable by every later step too, and a `${{ }}` reference
# to it would put the value in a `run:` body.
printf '%s' "$value" >"$PASSWORD_FILE"
