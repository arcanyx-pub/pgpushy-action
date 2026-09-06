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

# `pull_request` only. `pull_request_target` runs the base branch's workflow
# with a write token and the repository's secrets, and this action's whole job
# is to read a configuration file out of the tree and run a database tool
# against what it says — which is the last thing to hand a fork's branch.
# The comment has nowhere to go on any other event, and a run that silently
# does nothing is worse than one that says why.
case "$GITHUB_EVENT_NAME" in
    pull_request) ;;
    *)
        echo "::notice::pgpushy-action: comment: true has no effect on a '$GITHUB_EVENT_NAME' event; a plan comment needs a pull_request event"
        exit 0
        ;;
esac
[ -n "$PR_NUMBER" ] || fail "this $GITHUB_EVENT_NAME event carries no pull-request number to comment on"

[ -n "${GH_TOKEN:-}" ] ||
    fail "the 'token' input is empty; it defaults to the workflow's github.token and is what posts the comment"
: "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}" "${GITHUB_ACTION_PATH:?}"

body_file="$RUNNER_TEMP/pgpushy-comment-$PGPUSHY_ENV.md"
"$GITHUB_ACTION_PATH/scripts/comment-body.sh" >"$body_file"

# Read back rather than rebuilt, so the marker searched for is exactly the one
# written — the body builder sanitizes the environment name, and two
# spellings of that rule would eventually disagree.
marker=$(head -n 1 "$body_file")

# Scoped to comments this action wrote. The marker is visible in the rendered
# source of every plan comment, so a pull request author can paste it into a
# comment of their own; without this the action would then edit *that* comment
# and the plan would appear under someone else's name.
#
# Paginated, because the marker may be on a comment far down a long review
# thread, and a missed one becomes a second comment rather than an edited
# first.
existing=$(
    gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" |
        jq -r --arg marker "$marker" '
            first(
                (if type == "array" then .[] else empty end)
                | select(.body // "" | contains($marker))
                | select(.user.login == "github-actions[bot]" or .performed_via_github_app != null)
                | .id
            ) // empty
        '
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

# gh's own diagnostics go to the log rather than into the pipeline: a warning
# on stderr merged into stdout would reach jq as a parse error, and the real
# API error — usually a token without `pull-requests: write` — would be lost
# behind it.
if ! response=$(printf '%s' "$payload" | gh api -X "$method" "$endpoint" --input -); then
    fail "could not comment on pull request #$PR_NUMBER. The job needs 'permissions: pull-requests: write', and a fork's pull_request token is read-only whatever the workflow asks for."
fi

echo "$action the plan comment for env $PGPUSHY_ENV: $(printf '%s' "$response" | jq -r '.html_url // "?"')"
