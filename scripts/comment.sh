#!/usr/bin/env bash
#
# Upsert the plan as a pull-request comment: one comment per environment,
# edited in place.
#
# A schema pull request that gets ten pushes should carry one plan, not ten,
# so the comment is found by a hidden marker naming the environment and
# PATCHed. Two environments planned on the same pull request keep two
# comments, because they are two different answers.

set -euo pipefail

fail() {
    echo "::error::pgpushy-action: $1"
    exit 1
}

: "${PGPUSHY_ENV:?}" "${EXIT_CODE:?}"
: "${COMMENT:=false}" "${GITHUB_EVENT_NAME:=}" "${PR_NUMBER:=}"

[ "$COMMENT" = true ] || exit 0

# The comment has nowhere to go otherwise, and a push build silently doing
# nothing is worse than a push build saying why.
case "$GITHUB_EVENT_NAME" in
    pull_request | pull_request_target) ;;
    *)
        echo "::notice::pgpushy-action: comment: true has no effect on a '$GITHUB_EVENT_NAME' event; a plan comment needs a pull request"
        exit 0
        ;;
esac
[ -n "$PR_NUMBER" ] || fail "this $GITHUB_EVENT_NAME event carries no pull-request number to comment on"

: "${GH_TOKEN:?the 'token' input is empty; it defaults to \${{ github.token }} and is needed to comment}"
: "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}" "${GITHUB_ACTION_PATH:?}"

marker="<!-- pgpushy-action plan env=$PGPUSHY_ENV -->"
body_file="$RUNNER_TEMP/pgpushy-comment-$PGPUSHY_ENV.md"
"$GITHUB_ACTION_PATH/scripts/comment-body.sh" >"$body_file"

# Paginated: the marker may be on a comment far down a long review thread, and
# a missed one becomes a second comment rather than an edited first.
existing=$(
    gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" 2>&1 |
        jq -r --arg marker "$marker" 'if type == "array" then .[] else empty end
            | select(.body // "" | contains($marker)) | .id' | head -n 1
) || fail "could not list the comments on pull request #$PR_NUMBER"

# jq builds the request body so that nothing in a plan — backslashes, quotes,
# a line that looks like a shell substitution — has to survive being spliced
# into a command line.
payload=$(jq -n --rawfile body "$body_file" '{body: $body}')

if [ -n "$existing" ]; then
    action="updated"
    endpoint="repos/$GITHUB_REPOSITORY/issues/comments/$existing"
    method=PATCH
else
    action="posted"
    endpoint="repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments"
    method=POST
fi

# The API error is printed rather than swallowed: the usual cause is a token
# without `pull-requests: write`, and a comment that quietly never appears is
# the hardest version of that to diagnose.
if ! response=$(printf '%s' "$payload" | gh api -X "$method" "$endpoint" --input - 2>&1); then
    echo "$response" >&2
    fail "could not comment on pull request #$PR_NUMBER. The job needs 'permissions: pull-requests: write', and a fork's pull_request event gets a read-only token."
fi

echo "$action the plan comment for env $PGPUSHY_ENV: $(printf '%s' "$response" | jq -r '.html_url // "?"')"
