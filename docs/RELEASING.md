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

A Marketplace listing is out of scope for now. A release is the two tags, and
`uses: arcanyx-pub/pgpushy-action@v2` resolves against the repository whether
or not the action is listed.

## Why the major tag moves

`vX.Y.Z` is immutable and is what an audit reads. `vX` is what consumers
write, and it has to point at the newest release of that major version or it
would pin them to the day they adopted the action. Moving it is a force-push
of a tag, which is exactly why the recipe does it rather than a human.

The contract that makes this safe is the major version: within `v2`, an input
is never removed or given a different meaning, an output never changes what it
reports, and the pinned pgpushy moves only forward and only through a release.
Anything that would break a workflow written against `v2` is a `v3` and a
second moving tag, not a patch.

## The v2 contract

`v2` has **no `version` input**: each release pins one pgpushy in
[`pgpushy.pin`](../pgpushy.pin) and ships the SHA-256 of each of that release's
four binaries. A consumer pins pgpushy by pinning this action — `@v2.0.0` names
one pgpushy exactly, `@v2` picks up whichever one the newest `v2` release was
tested with — and reads the `pgpushy-version` output to see what they got.

That was a new major rather than a minor because GitHub only *warns* about an
input an action does not declare. A `v1` that stopped reading `version` would
have gone on running whatever it liked while a consumer's workflow still said
`version: 0.3.2`, which is the failure this whole repository exists to avoid.

**`v1` stays at 1.1.1 and is not maintained beyond security fixes.** It works,
it takes a `version` input, and anything that would be a feature there is a
reason to move to `v2` instead.

## Bumping the pinned pgpushy

The action downloads a pgpushy release and verifies it against a hash the
action ships, so bumping that version is a security-relevant change, not a
version-string edit. It is also the only way a repository's pgpushy moves, so
it is a release of this action.

```console
$ just bump-pgpushy 0.4.0
```

That downloads the four release binaries, hashes them, and refuses unless the
release's own `SHA256SUMS` and GitHub's per-asset digests both agree with what
it computed. It rewrites `pgpushy.pin` and stops, deliberately: the review is
the mechanism, and a script that fetched the hashes and committed them in one
move would make it a formality. So:

1. **Read the diff.** Four hashes and a version, together — that pairing is
   what the pin buys over a `SHA256SUMS` fetched at install time, which comes
   from the same origin as the binary and so can only catch corruption.
2. **Open a pull request.** The `pin` job downloads the four assets and
   verifies them against the file; the `e2e` job runs the action against a real
   database using that binary and checks out the pgpushy example project at
   `v<pinned>`, read from the same file. A version the e2e job has not planned
   and applied with is not a version this action pins.
3. **Stamp the CHANGELOG** — the pinned pgpushy is a `### Changed` entry,
   because it changes what every consumer of the moving tag runs — and update
   the version the README's [Which pgpushy](../README.md#which-pgpushy) section
   names. That sentence is there because a reader deciding whether to adopt the
   action should not have to open a checksum file to find out what it runs, and
   `scripts/pin-check.sh` fails when it and the pin disagree, so `just lint`
   catches a forgotten edit.
4. **Merge, then `just release X.Y.Z`.**

`just lint` and the `pin` job both run `scripts/pin-check.sh`, which is shape
only: one version, all four platforms, 64 characters of lowercase hex each.
Whether a hash is the *right* hash is not a question any local check can
answer — that is what downloading the assets in CI is for.
