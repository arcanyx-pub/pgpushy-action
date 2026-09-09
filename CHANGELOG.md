# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — where the
major version is what consumers pin, since `@v2` is a tag that moves.

## [Unreleased]

## [2.0.0] - 2026-09-09

### Changed

- The action pins one pgpushy release and ships the SHA-256 of each of its
  binaries in `pgpushy.pin`; the install verifies against that, not the
  release page. See [#5](https://github.com/arcanyx-pub/pgpushy-action/pull/5).

### Added

- `pgpushy-version` output.

### Removed

- The `version` input; a workflow that still sets it is refused by name. Pin
  pgpushy by pinning the action; `v1` keeps the input.

## [1.1.1] - 2026-09-09

### Fixed

- Masked passwords are escaped the way the runner expects, so a value
  containing `%25`, `%0A` or `%0D`, or a carriage return, is actually masked.
  See [#6](https://github.com/arcanyx-pub/pgpushy-action/pull/6).
- The exit step rejects an exit code outside 0, 1 and 2 instead of passing it
  to `exit`, and reports a routed destructive plan as a notice.

## [1.1.0] - 2026-09-09

### Added

- `on-destructive: continue`: a destructive plan (exit 2) reports rather than
  fails the step, with `exit-code` 2 and `destructive` true, so a workflow can
  route on the finding without `continue-on-error` — which swallows a refused
  plan and a destructive one alike, though they route to different people. Exit
  1 fails the step either way. This is not `allow_destructive`: pgpushy still
  exits 2, the artifact still lists every destructive step, and nothing is
  applied.
- `PGPASSWORD` and `PGPUSHY_PLAN_PASSWORD` are registered with the runner's log
  masker for the rest of the job, which covers a password minted during the run
  that no secret store has seen. A value under eight characters is left alone,
  because the runner redacts every occurrence of a masked string.
- Every `plan` writes its body — the pull-request comment's, without the hidden
  marker — to the run's step summary, so a plan on a push or a schedule is
  readable without opening the log.

## [1.0.0] - 2026-09-07

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
