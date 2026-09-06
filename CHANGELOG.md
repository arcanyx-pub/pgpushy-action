# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — where the
major version is what consumers pin, since `@v1` is a tag that moves.

## [Unreleased]

### Added

- The action itself: a composite action wrapping the pgpushy CLI, with
  `setup`, `validate`, `generate-check`, `plan` and `apply` commands.
- Version-pinned install from the pgpushy GitHub release, verified against the
  release's `SHA256SUMS` and cached under `RUNNER_TOOL_CACHE` by version and
  platform. A cache hit is re-verified rather than trusted for being present.
- `plan --plan-out` / `apply --plan` support, so the plan artifact can be
  uploaded, reviewed, approved through an environment's required reviewers,
  and applied exactly.
- `exit-code` and `destructive` outputs, so a workflow can route on a
  destructive plan (exit 2) instead of stopping on it.
- `comment: true`: one plan comment per environment on a pull request, edited
  in place. Plan output is fenced with a fence sized to its own content and
  stripped of control characters, so a branch under review cannot break out of
  the code block and write in the action's voice; only comments this action
  wrote are edited.
