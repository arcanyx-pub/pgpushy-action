# Releasing

This action is shell and YAML, so a release is a pair of tags and nothing
else. There is nothing to build, nothing to upload, and no registry — the
Marketplace and every `uses:` line read the repository at a git ref.

## The flow

1. On a feature branch, stamp the CHANGELOG: rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD` and add a fresh `## [Unreleased]` above it.
   Open the pull request and merge it. CI must be green — the `e2e` job is
   the one that matters, because it runs the action against a real database
   and a real plan artifact.
2. From an up-to-date `main`:
   ```console
   $ just release X.Y.Z
   ```
   That refuses a dirty tree, a branch other than `main`, and a version whose
   tag already exists; then it tags `vX.Y.Z`, force-moves `vX`, and pushes
   both.

## Why the major tag moves

`vX.Y.Z` is immutable and is what an audit reads. `vX` is what consumers
write, and it has to point at the newest release of that major version or it
would pin them to the day they adopted the action. Moving it is a force-push
of a tag, which is exactly why the recipe does it rather than a human.

The contract that makes this safe is the major version: within `v1`, an input
is never removed or given a different meaning, and an output never changes
what it reports. Anything that would break a workflow written against `v1`
is a `v2` and a second moving tag, not a patch.

## What a release does not pin

The `version` input, which names the pgpushy release to install, is the
consumer's to choose and is deliberately not defaulted. This action shipping a
new version does not change which pgpushy any repository runs — that is the
whole reason there is no `latest`.

CI installs one pgpushy version, set once as `PGPUSHY_VERSION` in
[`ci.yml`](../.github/workflows/ci.yml). Raising it is a normal pull request:
the `e2e` job checks out the pgpushy repository at the matching tag for its
example project, so the binary and the project it plans always agree.
