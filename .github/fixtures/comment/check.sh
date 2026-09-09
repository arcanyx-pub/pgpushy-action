#!/usr/bin/env bash
#
# Run the comment body builder over the fixture cases and check what it made.
#
# No database, no pull request, no token: the body builder is the part of this
# action a hostile branch can reach, so it is the part worth being able to run
# anywhere. Each case directory holds an `exit-code`, a `plan.log`, an optional
# `plan/` artifact and an `expect` file of literal lines the body must contain.
#
# Beyond the per-case expectations, every body is held to three invariants:
# the marker is the first line, the code fences are balanced (nothing in a plan
# managed to close one), and the whole thing fits in a GitHub comment.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
builder="$repo/scripts/comment-body.sh"

# GitHub's own limit, in characters. The builder budgets in bytes, which is
# the conservative reading; this asserts the thing GitHub actually enforces.
readonly GITHUB_LIMIT=65536

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

# A fenced block opened with N backticks is closed by the first line that is a
# run of N or more. The builder sizes its fence to be longer than anything in
# the content, so the longest all-backtick line in a correct body is its own
# fence, and those lines must come in pairs.
fences_balanced() {
    awk '
        /^`+$/ { if (length($0) > n) n = length($0) }
        { lines[NR] = $0 }
        END {
            if (n == 0) { print "no-fence"; exit }
            count = 0
            for (i = 1; i <= NR; i++) if (lines[i] ~ /^`+$/ && length(lines[i]) >= n) count++
            print (count > 0 && count % 2 == 0) ? "yes" : "no"
        }
    ' <<<"$1"
}

# The step summary is this same builder with WITHOUT_MARKER=1. It has to be the
# comment minus its marker and nothing else — one body, one truncation budget,
# no second spelling of the plan that could drift from the first.
assert_markerless() {
    local marked="$1" markerless="$2"

    case "$markerless" in
        *"<!-- pgpushy-action plan env="*) check "the marker-less body carries no marker" no ;;
        *) check "the marker-less body carries no marker" yes ;;
    esac

    if [ "$markerless" = "$(tail -n +2 <<<"$marked")" ]; then
        check "the marker-less body is the comment minus its first line" yes
    else
        check "the marker-less body is the comment minus its first line" no
    fi
}

assert_body() {
    local name="$1" body="$2" expect_file="$3"
    echo "$name"

    local first
    first=$(head -n 1 <<<"$body")
    case "$first" in
        "<!-- pgpushy-action plan env="*" -->") check "the marker is the first line" yes ;;
        *) check "the marker is the first line (got: $first)" no ;;
    esac

    check "the fences are balanced" "$(fences_balanced "$body")"

    local size
    size=$(printf '%s' "$body" | wc -c)
    if [ "$size" -le "$GITHUB_LIMIT" ]; then
        check "fits in a comment ($size bytes)" yes
    else
        check "fits in a comment ($size bytes > $GITHUB_LIMIT)" no
    fi

    if [ -f "$expect_file" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            if grep -qF -- "$line" <<<"$body"; then
                check "contains: $line" yes
            else
                check "contains: $line" no
            fi
        done <"$expect_file"
    fi
}

export GITHUB_SERVER_URL=https://github.com
export GITHUB_REPOSITORY=arcanyx-pub/pgpushy-action
export GITHUB_RUN_ID=1

# One place that spells out the builder's inputs, so the comment body and the
# step summary of a case differ in exactly the flag under test.
build() {
    local without_marker="$1" code="$2" log="$3" plan="$4"
    PGPUSHY_ENV=prod EXIT_CODE="$code" LOG_FILE="$log" PLAN_DIR="$plan" \
        WITHOUT_MARKER="$without_marker" "$builder"
}

for case_dir in "$here"/cases/*/; do
    name=$(basename "$case_dir")
    plan_dir=""
    [ ! -d "$case_dir/plan" ] || plan_dir="$case_dir/plan"
    code=$(cat "$case_dir/exit-code")
    body=$(build "" "$code" "$case_dir/plan.log" "$plan_dir")
    assert_body "$name" "$body" "$case_dir/expect"
    assert_markerless "$body" "$(build 1 "$code" "$case_dir/plan.log" "$plan_dir")"
done

# Built rather than committed: the point is a body the fixed parts alone would
# blow past, and several hundred kilobytes of generated noise is not something
# to keep in a repository.
oversized=$(mktemp -d)
huge=""
trap 'rm -rf "$oversized" "$huge"' EXIT
mkdir -p "$oversized/plan"
{
    echo '  plan --env prod'
    for i in $(seq 1 4000); do
        echo "DROP TABLE IF EXISTS a_table_with_a_long_and_tedious_name_$i CASCADE;"
    done
} >"$oversized/plan.log"
jq -n '{
    version: 1,
    target: {database: "shop", system_identifier: "1"},
    schemas: [{schema: "app", steps: 4000, destructive: 4000}],
    destructive: [range(4000) | {
        schema: "app",
        kind: "drop.table",
        path: ("app.a_table_with_a_long_and_tedious_name_" + (. | tostring))
    }],
    total: {steps: 4000, destructive: 4000}
}' >"$oversized/plan/summary.json"
# The backticks below are markdown in the expected headline, not substitutions.
# shellcheck disable=SC2016
printf '%s\n' \
    '### ⚠️ Destructive changes for `prod` (blocked: `allow_destructive` is not set for this environment)' \
    '... and 3950 more; see the plan artifact' >"$oversized/expect"
body=$(build "" 2 "$oversized/plan.log" "$oversized/plan")
assert_body "oversized (generated)" "$body" "$oversized/expect"
# Truncation included: the marker is dropped after the budget is spent, so a
# body that had to be cut is cut in the same place either way.
assert_markerless "$body" "$(build 1 2 "$oversized/plan.log" "$oversized/plan")"

# And the case the last resort exists for: 50 destructive steps whose names are
# each two kilobytes, so the parts that are never truncated are themselves over
# the budget and the whole body has to be cut.
huge=$(mktemp -d)
trap 'rm -rf "$oversized" "$huge"' EXIT
mkdir -p "$huge/plan"
echo '  plan --env prod' >"$huge/plan.log"
jq -n '{
    version: 1,
    target: {database: "shop", system_identifier: "1"},
    schemas: [{schema: "app", steps: 60, destructive: 60}],
    destructive: [range(60) | {
        schema: "app",
        kind: "drop.table",
        path: ("app." + ("n" * 2000) + (. | tostring))
    }],
    total: {steps: 60, destructive: 60}
}' >"$huge/plan/summary.json"
echo '... truncated: this comment did not fit. See the workflow run log.' >"$huge/expect"
body=$(build "" 2 "$huge/plan.log" "$huge/plan")
assert_body "unbounded names (generated)" "$body" "$huge/expect"
assert_markerless "$body" "$(build 1 2 "$huge/plan.log" "$huge/plan")"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all comment body checks passed"
