#!/usr/bin/env bash
#
# Run the masking script over a table of password shapes and check what it
# printed, byte for byte.
#
# The interesting half of `::add-mask::` is not the command, it is the escaping.
# The runner un-escapes a command's data before handing it to the secret masker,
# so the string that gets registered is not the string this script printed —
# and a password containing `%25`, or a newline, registers as something else
# entirely unless it was escaped on the way out. That is a bug with no symptom:
# the step says "masked", the log goes on showing the password. So every case
# here also runs the runner's un-escape backwards and asserts the round trip
# lands on the value that went in.
#
# No runner, no secrets, no database: the whole point is that this can be run
# anywhere, on the shapes a real minted token actually has.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
masker="$repo/scripts/mask.sh"

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

# The runner's own un-escape, in reverse order to the escaping — percent last,
# so that an escape sequence the password itself contained is not decoded a
# second time. This is the half of the contract that lives in the runner, and
# writing it out here is what makes the round trip below a test of anything.
unescape() {
    local s="$1"
    s=${s//%0D/$'\r'}
    s=${s//%0A/$'\n'}
    s=${s//%25/%}
    printf '%s' "$s"
}

# `-` means "not set at all", which is a different case from an empty value and
# is worth telling apart: an action that ran `mask.sh` with `set -u` and no
# PGPASSWORD would fail the step rather than skip the masking.
run_mask() {
    local pg="$1" plan="$2"
    # env stops reading options at the first assignment, so every -u goes first.
    local -a unset_args=() set_args=()
    if [ "$pg" = - ]; then unset_args+=(-u PGPASSWORD); else set_args+=("PGPASSWORD=$pg"); fi
    if [ "$plan" = - ]; then
        unset_args+=(-u PGPUSHY_PLAN_PASSWORD)
    else
        set_args+=("PGPUSHY_PLAN_PASSWORD=$plan")
    fi
    env "${unset_args[@]}" "${set_args[@]}" "$masker"
}

# stdout, exactly: the remaining arguments are the lines it must consist of,
# and no arguments means it must print nothing at all.
expect_stdout() {
    local what="$1" pg="$2" plan="$3"
    shift 3

    : >"$work/expected"
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$work/expected"

    if ! run_mask "$pg" "$plan" >"$work/got" 2>"$work/err"; then
        check "$what (the script failed: $(head -c 200 "$work/err"))" no
        return
    fi
    if cmp -s "$work/expected" "$work/got"; then
        check "$what" yes
    else
        check "$what" no
        diff -u "$work/expected" "$work/got" | sed 's/^/        /' || true
    fi
}

# What the runner will actually register, for a value long enough to be masked.
expect_round_trip() {
    local what="$1" value="$2"

    run_mask "$value" - >"$work/got"
    local line
    if ! line=$(grep -m1 '^::add-mask::' "$work/got"); then
        check "$what: an ::add-mask:: line was printed" no
        return
    fi

    unescape "${line#'::add-mask::'}" >"$work/unescaped"
    printf '%s' "$value" >"$work/value"
    if cmp -s "$work/value" "$work/unescaped"; then
        check "$what: the runner un-escapes it back to the password" yes
    else
        check "$what: the runner un-escapes it back to the password" no
    fi

    # A password reaches the masker as one command, whatever it contains: a raw
    # newline in the data would end the command early and print the rest of the
    # password as an ordinary log line.
    if [ "$(wc -l <"$work/got")" = 2 ]; then
        check "$what: it is one line of command and one of confirmation" yes
    else
        check "$what: it is one line of command and one of confirmation" no
    fi
}

readonly MASKED="pgpushy-action: masked PGPASSWORD"
readonly MASKED_PLAN="pgpushy-action: masked PGPUSHY_PLAN_PASSWORD"
short_warning() {
    printf '%s' "::warning::pgpushy-action: $1 is under 8 characters, so it is not masked: the runner redacts every occurrence of a masked string, and a short one would black out unrelated text in this job's log"
}

echo "mask.sh: what gets printed"

expect_stdout "an ordinary password is masked" \
    postgres-ci-pw - \
    "::add-mask::postgres-ci-pw" "$MASKED"

expect_stdout "a percent sign is escaped" \
    'pass%word1' - \
    "::add-mask::pass%25word1" "$MASKED"

# The three sequences the runner decodes. A password containing one of them
# literally is the case escaping exists for: unescaped, the runner would
# register a *different* string and the real password would stay in the log.
expect_stdout "a literal %25 is escaped, not decoded" \
    'abc%25defg' - \
    "::add-mask::abc%2525defg" "$MASKED"

expect_stdout "a literal %0A is escaped, not decoded" \
    'tok%0Aen123' - \
    "::add-mask::tok%250Aen123" "$MASKED"

expect_stdout "a literal %0D is escaped, not decoded" \
    'tok%0Den123' - \
    "::add-mask::tok%250Den123" "$MASKED"

expect_stdout "a raw carriage return is escaped" \
    "$(printf 'abcdefgh\rijk')" - \
    "::add-mask::abcdefgh%0Dijk" "$MASKED"

expect_stdout "a raw newline is escaped" \
    "$(printf 'abcdefgh\nijk')" - \
    "::add-mask::abcdefgh%0Aijk" "$MASKED"

expect_stdout "a value already carrying %25 and a newline keeps both" \
    "$(printf 'a%%25b\ncdefghi')" - \
    "::add-mask::a%2525b%0Acdefghi" "$MASKED"

# The floor, and both sides of it. Eight characters is the shortest value this
# script will mask.
expect_stdout "a short password is not masked, and says so" \
    pw - \
    "$(short_warning PGPASSWORD)"

expect_stdout "seven characters is short" \
    seven77 - \
    "$(short_warning PGPASSWORD)"

expect_stdout "eight characters is masked" \
    eight888 - \
    "::add-mask::eight888" "$MASKED"

expect_stdout "an empty password is skipped in silence" "" -

expect_stdout "an unset password is skipped in silence" - -

expect_stdout "the plan database's password is masked too" \
    - plan-db-password \
    "::add-mask::plan-db-password" "$MASKED_PLAN"

expect_stdout "a short plan-database password says which variable it was" \
    - short \
    "$(short_warning PGPUSHY_PLAN_PASSWORD)"

expect_stdout "both are masked, target first" \
    postgres-ci-pw plan-db-password \
    "::add-mask::postgres-ci-pw" "$MASKED" \
    "::add-mask::plan-db-password" "$MASKED_PLAN"

echo "mask.sh: what the runner ends up registering"

expect_round_trip "an ordinary password" postgres-ci-pw
expect_round_trip "a percent sign" 'pass%word1'
expect_round_trip "a literal %25" 'abc%25defg'
expect_round_trip "a literal %0A" 'tok%0Aen123'
expect_round_trip "a literal %0D" 'tok%0Den123'
expect_round_trip "a raw carriage return" "$(printf 'abcdefgh\rijk')"
expect_round_trip "a raw newline" "$(printf 'abcdefgh\nijk')"
expect_round_trip "a percent-encoded token" 'v1%3Aabc%2Fdef%2Bghi%3D'
expect_round_trip "a run of percent signs" '%%%%%%%%%%'
# The backticks and the dollar below are password characters, not shell syntax.
# shellcheck disable=SC2016
expect_round_trip "quotes, backslashes and dollars" 'a"b\\c$d(e)f;g`h`'

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all mask checks passed"
