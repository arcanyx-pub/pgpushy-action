#!/usr/bin/env bash
#
# Run the minting script over a table of commands and check what came out of
# each one.
#
# What this script does is take an arbitrary command's standard output and call
# it a password, so the interesting cases are all the ways that goes wrong: a
# command that printed nothing, one that printed a paragraph, one that failed
# after printing, one that never returns. Every one of those must fail by the
# name of the input the workflow author wrote — and none of them may put the
# value in the log, which is the whole reason the password is minted here
# rather than in a step of their own.
#
# No runner, no cloud CLI, no database: a fake minter is a `printf`, and the
# shapes it can produce are the same shapes `aws rds generate-db-auth-token`
# can.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
minter="$repo/scripts/mint.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

password_file="$work/pgpushy-action-password"

failures=0
check() {
    local what="$1" ok="$2"
    if [ "$ok" = yes ]; then
        echo "  ok    $what"
    else
        echo "  FAIL  $what"
        failures=$((failures + 1))
    fi
}

# `stat` is one of the places GNU and BSD disagree, and this file's mode is
# part of the contract rather than a detail: it is a live credential sitting in
# a directory every later step of the job can read.
file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# mint.sh writes the command's raw output to a scratch file beside the password
# file, and that file holds the password too. Nothing may leave one behind.
scratch_left() {
    local f
    for f in "$password_file".*; do
        [ -e "$f" ] && return 0
    done
    return 1
}

# The last run's status, stdout and stderr. Each case reads whichever of them
# it is about.
status=0
run_mint() {
    local command="$1"
    shift

    rm -f "$password_file"
    status=0
    env \
        INPUT_NAME=password-command \
        VAR_NAME=PGPASSWORD \
        MINT_COMMAND="$command" \
        PASSWORD_FILE="$password_file" \
        "$@" \
        "$minter" >"$work/out" 2>"$work/err" || status=$?
}

# The password, byte for byte and with nothing after it: the file is read with
# `$(cat …)`, which would hide a trailing newline by stripping it.
expect_password() {
    local what="$1" command="$2" want="$3"
    shift 3

    run_mint "$command" "$@"
    if [ "$status" != 0 ]; then
        check "$what (the script failed: $(head -c 300 "$work/out" "$work/err"))" no
        return
    fi

    printf '%s' "$want" >"$work/want"
    if cmp -s "$work/want" "$password_file"; then
        check "$what" yes
    else
        check "$what" no
        diff -u "$work/want" "$password_file" | sed 's/^/        /' || true
    fi

    if scratch_left; then
        check "$what -> leaves no scratch file" no
    else
        check "$what -> leaves no scratch file" yes
    fi
}

# A refusal is only useful if it names the input, and it is only safe if the
# value is nowhere in what the step printed — on either stream.
expect_refusal() {
    local what="$1" command="$2" says="$3" secret="$4"
    shift 4

    run_mint "$command" "$@"

    if [ "$status" != 0 ]; then
        check "$what -> fails" yes
    else
        check "$what -> fails (exited 0)" no
    fi

    if grep -qF "$says" "$work/out"; then
        check "$what -> says: $says" yes
    else
        check "$what -> says: $says (got: $(head -c 300 "$work/out"))" no
    fi

    if [ -n "$secret" ] && grep -qF -- "$secret" "$work/out" "$work/err"; then
        check "$what -> never prints what the command produced" no
    else
        check "$what -> never prints what the command produced" yes
    fi

    if [ -e "$password_file" ] || scratch_left; then
        check "$what -> writes no password file, and leaves no scratch file" no
    else
        check "$what -> writes no password file, and leaves no scratch file" yes
    fi
}

echo "mint.sh: a command that produces a password"

expect_password "one line with a trailing newline is the password" \
    "printf '%s\\n' minted-token-123" minted-token-123

expect_password "no trailing newline at all is the same password" \
    "printf '%s' minted-token-123" minted-token-123

expect_password "only one trailing newline is stripped, so trailing spaces survive" \
    "printf '%s  \\n' minted-token-123" "minted-token-123  "

# The point of running the command with the job's environment: a minting CLI
# reads its credentials from there, and so does the fake one here. The
# expansion below is the minted command's, not this script's.
# shellcheck disable=SC2016
expect_password "the command inherits the job's environment" \
    'printf %s "$FAKE_TOKEN"' fake-token-abcdef FAKE_TOKEN=fake-token-abcdef

mkdir -p "$work/sub"
printf '%s\n' token-from-a-subdirectory >"$work/sub/token"
expect_password "the command runs in working-directory" \
    "cat token" token-from-a-subdirectory \
    "WORKING_DIRECTORY=$work/sub"

expect_password "a pipeline that succeeds is a password" \
    "printf '%s\\n' ' padded-token-1 ' | tr -d ' '" padded-token-1

echo "mint.sh: what the runner is told to mask"

run_mint "printf '%s\\n' minted-token-123"
if grep -qxF '::add-mask::minted-token-123' "$work/out"; then
    check "the value is handed to the log masker" yes
else
    check "the value is handed to the log masker (got: $(cat "$work/out"))" no
fi
if grep -qxF 'pgpushy-action: masked PGPASSWORD' "$work/out"; then
    check "the confirmation names the variable" yes
else
    check "the confirmation names the variable" no
fi
if [ "$(grep -cF minted-token-123 "$work/out")" = 1 ]; then
    check "exactly one line carries the value: the mask command" yes
else
    check "exactly one line carries the value: the mask command" no
fi

# The escaping is mask.sh's, reached through the same function, because a
# second spelling of it is a second thing that can be wrong: the runner
# un-escapes a command's data before the masker sees it, so a token containing
# `%25` registers as something else unless it was escaped on the way out.
run_mint "printf '%s\\n' 'mint%25ed-token'"
if grep -qxF '::add-mask::mint%2525ed-token' "$work/out"; then
    check "a percent-encoded token is escaped the way mask.sh escapes it" yes
else
    check "a percent-encoded token is escaped the way mask.sh escapes it (got: $(cat "$work/out"))" no
fi


echo "mint.sh: the file it hands to the run step"

run_mint "printf '%s\\n' minted-token-123"
if [ "$(file_mode "$password_file")" = 600 ]; then
    check "the password file is readable by this user only" yes
else
    check "the password file is readable by this user only (mode $(file_mode "$password_file"))" no
fi

# A file left behind by an earlier step of the same job must never be read as
# this run's password, so it goes before the command runs rather than after it.
printf '%s' a-password-from-an-earlier-run >"$password_file"
run_mint "printf '%s\\n' minted-token-123"
if [ "$(cat "$password_file")" = minted-token-123 ]; then
    check "a stale password file is replaced, not appended to" yes
else
    check "a stale password file is replaced, not appended to" no
fi

printf '%s' a-password-from-an-earlier-run >"$password_file"
status=0
env INPUT_NAME=password-command VAR_NAME=PGPASSWORD \
    MINT_COMMAND="exit 1" PASSWORD_FILE="$password_file" \
    "$minter" >"$work/out" 2>"$work/err" || status=$?
if [ "$status" != 0 ] && [ ! -e "$password_file" ]; then
    check "a failed mint leaves no stale password behind either" yes
else
    check "a failed mint leaves no stale password behind either" no
fi

echo "mint.sh: standard error is the command's own channel"

run_mint "printf '%s\\n' 'ExpiredToken: the security token has expired' >&2; printf '%s\\n' tok-abcdefgh"
if grep -qF 'the security token has expired' "$work/err"; then
    check "a warning on stderr reaches the log even when the mint succeeded" yes
else
    check "a warning on stderr reaches the log even when the mint succeeded" no
fi

run_mint "printf '%s\\n' 'AccessDenied: not authorized to perform rds:GenerateDBAuthToken' >&2; exit 254"
if grep -qF 'not authorized to perform rds:GenerateDBAuthToken' "$work/err"; then
    check "a failing command's own error is what a human reads" yes
else
    check "a failing command's own error is what a human reads" no
fi

echo "mint.sh: commands that do not produce a password"

expect_refusal "a command that prints nothing" \
    "true" \
    "'password-command' produced an empty password" ""

expect_refusal "a command that prints one empty line" \
    "printf '\\n'" \
    "'password-command' produced an empty password" ""

expect_refusal "two trailing newlines are not one" \
    "printf '%s\\n\\n' minted-token-123" \
    "'password-command' produced a password containing a newline" minted-token-123

expect_refusal "a password with a newline in the middle" \
    "printf '%s\\n%s\\n' line-one-abc line-two-def" \
    "'password-command' produced a password containing a newline" line-one-abc

expect_refusal "a command that prints only whitespace" \
    "printf '   \\n'" \
    "'password-command' produced an empty password" ""

# No credential API mints eight characters. A short result is an error string
# or a truncated read, and the runner's masker would decline to register it —
# so it is refused here rather than handed to pgpushy unmasked.
expect_refusal "a result too short to be a credential" \
    "printf '%s\\n' short" \
    "'password-command' produced a password shorter than 8 characters" ""

expect_refusal "seven characters is still too short" \
    "printf '%s\\n' seven77" \
    "'password-command' produced a password shorter than 8 characters" ""

expect_password "eight characters is a password" \
    "printf '%s\\n' eight888" eight888

# The carriage return a CRLF minter leaves behind once the trailing newline is
# stripped. Trimming it would mean connecting with something the command did
# not print, so it is refused by name like any other line break.
expect_refusal "a CRLF minter" \
    "printf '%s\\r\\n' minted-token-123" \
    "'password-command' produced a password containing a carriage return" minted-token-123

expect_refusal "a carriage return in the middle" \
    "printf 'first-half\\rsecond-half\\n'" \
    "'password-command' produced a password containing a carriage return" second-half

# Bash drops a NUL from a command substitution and carries on, which would make
# the password something other than what the command printed.
expect_refusal "output containing a NUL byte" \
    "printf 'minted\\000token-123\\n'" \
    "'password-command' produced output containing a NUL byte" token-123

expect_refusal "a command that fails after printing" \
    "printf '%s\\n' never-logged-token; exit 3" \
    "'password-command' exited 3" never-logged-token

expect_refusal "a command that is not a command" \
    "no-such-minting-cli --token" \
    "'password-command' exited 127" ""

# -e and -o pipefail, so a mint whose first stage failed is a failed mint
# rather than a password made of whatever the rest of the pipeline printed.
expect_refusal "a pipeline whose first stage fails" \
    "no-such-minting-cli | tr -d ' '" \
    "'password-command' exited" ""

echo "mint.sh: a job that asked bash to trace everything"

# SHELLOPTS is exported into every step by anything that writes it to
# GITHUB_ENV, and a bash that starts with xtrace on traces each expansion to
# standard error — which is the log, before the mask exists. The script turns
# it off before it touches the value, and the minting command inherits the
# switch in that state.
run_mint "printf '%s\\n' minted-token-123" SHELLOPTS=xtrace
if [ "$status" = 0 ] && [ "$(cat "$password_file")" = minted-token-123 ]; then
    check "SHELLOPTS=xtrace still mints the password" yes
else
    check "SHELLOPTS=xtrace still mints the password (exit $status)" no
fi
if [ "$(grep -cF minted-token-123 "$work/out")" = 1 ] && ! grep -qF minted-token-123 "$work/err"; then
    check "SHELLOPTS=xtrace traces the value onto neither stream" yes
else
    check "SHELLOPTS=xtrace traces the value onto neither stream (out $(grep -cF minted-token-123 "$work/out"), err $(grep -cF minted-token-123 "$work/err"))" no
fi

echo "mint.sh: a command that never returns"

expect_refusal "a command that outlives the timeout" \
    "sleep 30" \
    "'password-command' did not produce a password within 2s" "" \
    PGPUSHY_ACTION_MINT_TIMEOUT=2

# A minter that ignores the deadline's first signal is killed five seconds
# later, and that is still a timeout rather than an ordinary non-zero exit.
expect_refusal "a command that ignores the deadline's signal" \
    'trap "" TERM; sleep 30' \
    "'password-command' did not produce a password within 1s" "" \
    PGPUSHY_ACTION_MINT_TIMEOUT=1

# The macOS half of the same guard. GNU coreutils' timeout is on every Linux
# runner and on no macOS one, so the script falls back to a watchdog of its
# own — and a fallback nothing exercises is a fallback that works until the day
# it is needed. PATH is cut down to the utilities the script and the fake
# minter use, with no timeout in it.
mkdir -p "$work/bin"
for tool in bash sleep mktemp rm cat dirname; do
    ln -sf "$(command -v "$tool")" "$work/bin/$tool"
done
expect_refusal "a command that outlives the timeout, on a runner with no timeout(1)" \
    "sleep 30" \
    "'password-command' did not produce a password within 2s" "" \
    PGPUSHY_ACTION_MINT_TIMEOUT=2 "PATH=$work/bin"

# And the other half of that fallback: a command that finishes must not wait
# for the watchdog, and must not be reported as having timed out.
status=0
env INPUT_NAME=password-command VAR_NAME=PGPASSWORD \
    MINT_COMMAND="printf '%s\\n' minted-token-123" PASSWORD_FILE="$password_file" \
    PGPUSHY_ACTION_MINT_TIMEOUT=30 "PATH=$work/bin" \
    "$minter" >"$work/out" 2>"$work/err" || status=$?
if [ "$status" = 0 ] && [ "$(cat "$password_file")" = minted-token-123 ]; then
    check "a command that returns is not waited on by the watchdog" yes
else
    check "a command that returns is not waited on by the watchdog" no
fi

# GNU timeout signals the command's whole process group, so a minter that
# backgrounded something does not outlive its own deadline. The watchdog has to
# do the same, and this is the case that tells the two apart: the background
# child writes a marker after the deadline has passed, and must never get to.
marker="$work/the-child-outlived-the-mint"
rm -f "$marker"
expect_refusal "a minter's background child dies with it, on a runner with no timeout(1)" \
    "(sleep 3; printf x >'$marker') & sleep 30" \
    "'password-command' did not produce a password within 1s" "" \
    PGPUSHY_ACTION_MINT_TIMEOUT=1 "PATH=$work/bin"
sleep 4
if [ -e "$marker" ]; then
    check "the killed minter's background child wrote nothing afterwards" no
else
    check "the killed minter's background child wrote nothing afterwards" yes
fi

echo "mint.sh: the plan database's password is the same script"

run_mint "printf '%s\\n' plan-db-token-1" VAR_NAME=PGPUSHY_PLAN_PASSWORD INPUT_NAME=plan-password-command
if grep -qxF 'pgpushy-action: masked PGPUSHY_PLAN_PASSWORD' "$work/out"; then
    check "the confirmation names the plan database's variable" yes
else
    check "the confirmation names the plan database's variable" no
fi

expect_refusal "a plan-database mint is refused by its own input's name" \
    "true" \
    "'plan-password-command' produced an empty password" "" \
    INPUT_NAME=plan-password-command VAR_NAME=PGPUSHY_PLAN_PASSWORD

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all mint checks passed"
