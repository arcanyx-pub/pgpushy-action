#!/usr/bin/env bash
#
# Run the last step of the action over its whole truth table.
#
# This is the step that decides whether a run failed, so it is worth checking
# as a table rather than in passing: `on-destructive: continue` may turn a
# destructive plan (exit 2) into a successful step and must never turn a
# refusal (exit 1) into one, and a code outside the contract must not be passed
# to `exit`, which takes its argument modulo 256 and would report 256 as
# success.
#
# No runner and no pgpushy: the inputs are three environment variables and the
# outputs are a status and an annotation.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
exiter="$repo/scripts/exit.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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

# `-` means the variable is not set, which for EXIT_CODE is the case where the
# run step recorded nothing and for COMMAND is a bug in action.yml.
run_exit() {
    local code="$1" command="$2" on_destructive="$3"
    # env stops reading options at the first assignment, so every -u goes first.
    local -a unset_args=() set_args=()
    if [ "$code" = - ]; then unset_args+=(-u EXIT_CODE); else set_args+=("EXIT_CODE=$code"); fi
    if [ "$command" = - ]; then unset_args+=(-u COMMAND); else set_args+=("COMMAND=$command"); fi
    if [ "$on_destructive" = - ]; then
        unset_args+=(-u ON_DESTRUCTIVE)
    else
        set_args+=("ON_DESTRUCTIVE=$on_destructive")
    fi
    env "${unset_args[@]}" "${set_args[@]}" "$exiter"
}

# `says` is what the step must print on stdout: `quiet`, or the annotation kind
# it has to open with. The message text is not asserted — the kind is the
# contract, because a notice is an annotation on the run and a plain line is
# not.
row() {
    local code="$1" command="$2" on_destructive="$3" want_status="$4" says="$5"
    local what="EXIT_CODE=$code COMMAND=$command ON_DESTRUCTIVE=$on_destructive"

    local status=0
    run_exit "$code" "$command" "$on_destructive" >"$work/out" 2>"$work/err" || status=$?

    if [ "$status" = "$want_status" ]; then
        check "$what -> exits $want_status" yes
    else
        check "$what -> exits $want_status (got $status)" no
    fi

    local first
    first=$(head -n 1 "$work/out")
    case "$says" in
        quiet)
            if [ -s "$work/out" ]; then
                check "$what -> says nothing (got: $first)" no
            else
                check "$what -> says nothing" yes
            fi
            ;;
        *)
            case "$first" in
                "$says"*) check "$what -> opens with $says" yes ;;
                *) check "$what -> opens with $says (got: $first)" no ;;
            esac
            ;;
    esac
}

echo "exit.sh: the codes pgpushy contracts to return"

#   code  command   on-destructive  status  stdout
row 0 plan fail 0 quiet
row 0 plan continue 0 quiet
row 0 apply fail 0 quiet
row 0 setup - 0 quiet

row 1 plan fail 1 quiet
# The whole point of the input: a refusal is not a destructive finding, and
# continue-on-error is what cannot tell them apart.
row 1 plan continue 1 quiet
row 1 apply continue 1 quiet

row 2 plan fail 2 quiet
row 2 plan - 2 quiet
row 2 plan continue 0 "::notice::pgpushy-action:"
# Only `plan` reports a destructive finding, so a 2 from anywhere else is a
# failure whatever the input says.
row 2 apply continue 2 quiet
row 2 validate continue 2 quiet

echo "exit.sh: codes it must not pass on"

# `exit 256` is a success and `exit 300` is 44. A code outside the contract
# fails the step by name instead, and the exit-code output still carries what
# pgpushy actually returned.
row 256 plan continue 1 "::error::pgpushy-action:"
row 300 plan fail 1 "::error::pgpushy-action:"
row 3 plan fail 1 "::error::pgpushy-action:"
row -1 plan fail 1 "::error::pgpushy-action:"
row 101 plan continue 1 "::error::pgpushy-action:"
row two plan fail 1 "::error::pgpushy-action:"
row "" plan fail 1 "::error::pgpushy-action:"
row - plan fail 1 "::error::pgpushy-action:"

# COMMAND comes from action.yml on every path, so an unset one is a bug in the
# action rather than in a workflow; it still must not be guessed at.
status=0
run_exit 2 - continue >"$work/out" 2>"$work/err" || status=$?
if [ "$status" != 0 ]; then
    check "an unset COMMAND fails rather than being guessed at" yes
else
    check "an unset COMMAND fails rather than being guessed at" no
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all exit checks passed"
