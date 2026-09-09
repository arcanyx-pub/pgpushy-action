# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — where the
major version is what consumers pin, since `@v1` is a tag that moves.

## [Unreleased]

### Fixed

- The value handed to the log masker is escaped the way `@actions/core` escapes
  a workflow command's data — `%` to `%25`, carriage return to `%0D`, newline
  to `%0A`. The runner un-escapes that data before the masker sees it, so a
  password containing `%25`, `%0A` or `%0D` literally — a minted token is
  routinely percent-encoded — registered a *different* string than the one in
  the environment: the step reported "masked" and the log went on showing the
  password.
- A password carrying a carriage return or a newline is masked rather than
  refused, and no longer has its tail printed. The runner ends a log line on a
  carriage return as well as a newline, so a value containing one used to reach
  the log unmasked past that point; escaping keeps the whole value inside one
  command, and the runner registers each line of a multi-line secret itself.
- `exit.sh` rejects an exit code outside pgpushy's contract instead of passing
  it to `exit`, which takes its argument modulo 256 and would report 256 as a
  success; a missing code is an error rather than a guess, and both say so as
  `::error::`. A destructive plan reported under `on-destructive: continue` is
  now a `::notice::`, so the finding lands in the run's annotations.

### Changed

- README: `on-destructive: continue` gives up the gate the plan step's failure
  was providing. A plan job that succeeds is one whose artifact uploads and
  whose `needs:` dependents run — an `apply` job included, which passes
  `--auto-approve` — leaving the deploy environment's required reviewers as the
  only gate. The documented shape now puts that gate back explicitly, on the
  `destructive` output: on the upload step, and on the apply job's `if:` by way
  of a job output. It still permits nothing in pgpushy, which exits 2 and
  records every drop in the artifact.
- README: the step summary and the pull-request comment are the same body, but
  not the same bytes — the runner scrubs the summary through the secret masker
  before uploading it and the comment is posted through the API unscrubbed, and
  a password that equals an identifier blacks that word out wherever the
  redaction reaches.
- `mask.sh` and `exit.sh` are checked against fixture tables, run by `just lint`
  and by CI: password shapes to expected output, including a local
  reimplementation of the runner's un-escape that asserts the round trip lands
  on the password that went in, and the exit step's whole truth table.

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
