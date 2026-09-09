# pgpushy-action

Run [pgpushy](https://github.com/arcanyx-pub/pgpushy) in GitHub Actions:
validate a schema tree on a pull request, plan against a real database and
post the plan as a comment, and apply **exactly the plan that was reviewed**
behind an environment's required reviewers.

The plan-artifact flow pgpushy ships — plan under a preview role, persist the
plan, approve *that artifact*, apply exactly it under a deploy role — is not
really a CLI shape. It is a CI shape, and GitHub already supplies every piece
of it: `environment:` with required reviewers is the approval gate, two
environments give two credential sets, and artifacts carry the plan between
jobs so the approval applies to a reviewed object rather than to a recomputed
one. This action is the glue.

```yaml
- uses: arcanyx-pub/pgpushy-action@v1
  with:
    command: plan
    version: 0.3.2
    env: prod
```

## The deployment shape

Two jobs. The first plans under credentials that can read; the second applies
under credentials that can write, and only after a human has approved the
`db-deploy` environment.

```yaml
# .github/workflows/schema.yml
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  plan:
    runs-on: ubuntu-latest
    environment: db-preview          # credentials that can read, not write
    permissions:
      contents: read
      pull-requests: write           # only for `comment: true`
    steps:
      - uses: actions/checkout@v7

      - uses: arcanyx-pub/pgpushy-action@v1
        with:
          command: plan
          version: 0.3.2
          env: prod                  # the [env.prod] block in pgpushy.toml
          plan-out: ./plan
          # A fork's token cannot comment, so asking it to would fail the run.
          comment: ${{ !github.event.pull_request.head.repo.fork }}
        env:
          PGPASSWORD: ${{ secrets.DB_PREVIEW_PASSWORD }}

      # The reviewed object. A destructive plan exits 2 and fails the step
      # above, so nothing reaches here for a human to approve by accident —
      # which is what `on-destructive: continue` would give up, and why a
      # workflow that sets it gates this step on the `destructive` output.
      - uses: actions/upload-artifact@v7
        with:
          name: pgpushy-plan
          path: ./plan

  apply:
    needs: plan
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: db-deploy           # required reviewers — this is the gate
    steps:
      # Not the source tree: the apply order, the plans and the seeds all
      # live in the artifact. What this job needs from the repository is the
      # one file that says which database `prod` is.
      - uses: actions/checkout@v7
        with:
          sparse-checkout: pgpushy.toml
          sparse-checkout-cone-mode: false

      - uses: actions/download-artifact@v8
        with:
          name: pgpushy-plan
          path: ./plan

      - uses: arcanyx-pub/pgpushy-action@v1
        with:
          command: apply
          version: 0.3.2
          env: prod
          plan: ./plan               # apply exactly this
        env:
          PGPASSWORD: ${{ secrets.DB_DEPLOY_PASSWORD }}
```

This shape serves same-repository branches. A pull request from a fork gets
no secrets and a read-only token, so `PGPASSWORD` would be empty and the plan
job would fail at the connection — before it could comment, which it also
could not do.

`--plan` mode reads no source tree — that is the point of the artifact, and
the difference between a deploy job that carries a source tree and one that
carries only what was approved. It does still need a `pgpushy.toml`, because
`--env prod` names a block in one; a sparse checkout of that single file is
enough, and so is a deploy-only config that contains nothing but the
environment.

## Checks on a pull request

Neither of these connects to anything, so they need no environment, no
credentials and no service:

```yaml
on: pull_request

permissions:
  contents: read

jobs:
  schema:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # The whole offline pipeline: discovery, parsing, the statement
      # allow-list, schema resolution, the validity checks and cross-schema
      # ordering.
      - uses: arcanyx-pub/pgpushy-action@v1
        with:
          command: validate
          version: 0.3.2

      # Vendored SQL from a dependency must match what the locked version
      # emits: a bump that changes the emitted SQL lands as a reviewed diff.
      - uses: arcanyx-pub/pgpushy-action@v1
        with:
          command: generate-check
          version: 0.3.2
```

## Inputs

| input | required | default | notes |
| --- | --- | --- | --- |
| `command` | yes | | `setup`, `validate`, `generate-check`, `plan` or `apply`. |
| `version` | yes | | The pgpushy release to install, e.g. `0.3.2`. A leading `v` is accepted. |
| `env` | for `plan`/`apply` | | The `[env.<name>]` block to reconcile against. Rejected for the other commands. |
| `config` | no | | Passed as `--config`. Relative to `working-directory`. |
| `working-directory` | no | `.` | Where pgpushy runs. |
| `plan-out` | `plan` only | | Where the plan artifact is written. Relative to `working-directory`. |
| `plan` | `apply` only | | A plan artifact to apply exactly. Relative to `working-directory`. |
| `comment` | `plan` only | `false` | Upsert the plan as a pull-request comment. |
| `on-destructive` | `plan` only | `fail` | `fail` or `continue`: whether a destructive plan (exit 2) fails the step. Exit 1 fails it either way. |
| `token` | no | `${{ github.token }}` | Used only to post that comment. |

`setup` installs the binary, puts it on `PATH`, and stops — for a workflow
that wants to call pgpushy itself.

There is **no `version: latest`**. A plan and the apply of that plan should be
run by the same program, and a schema tool that changed under a repository
between two runs of one workflow would make that untrue.

## Outputs

| output | value |
| --- | --- |
| `exit-code` | pgpushy's exit code: `0` success, `1` refused, `2` a valid plan that would destroy something. |
| `destructive` | `true`/`false` for `plan`, empty otherwise. |
| `pgpushy-path` | Absolute path of the installed binary. It is also on `PATH`. |

The step **fails when pgpushy does**, exit 2 included. A workflow that would
rather route on a destructive plan than stop on it says so with
`on-destructive: continue`:

```yaml
- id: plan
  uses: arcanyx-pub/pgpushy-action@v1
  with:
    command: plan
    version: 0.3.2
    env: prod
    on-destructive: continue   # exit 2 reports; exit 1 still fails

- if: steps.plan.outputs.destructive == 'true'
  run: gh pr edit "$PR" --add-label destructive
```

`on-destructive: continue` is **not `allow_destructive`**: pgpushy still exits
2, the artifact still lists every destructive step, and nothing is applied —
the input changes only how the step reports the finding.

What it does change is the **gate that step failure was providing**. By
default a destructive plan fails the plan job, and everything downstream of it
— the artifact upload, and any job with `needs: plan` — is skipped. Ask the
step to succeed and all of that runs: the artifact uploads, the apply job
starts, and `apply` passes `--auto-approve`. The only gate left is the required
reviewers on the deploy `environment:`, which is a human reading a diff rather
than a pipeline that stopped.

So a workflow that turns the failure off puts the gate back explicitly, on the
`destructive` output — on the upload, so a destructive plan never becomes an
approvable artifact:

```yaml
- if: steps.plan.outputs.destructive != 'true'
  uses: actions/upload-artifact@v7
  with:
    name: pgpushy-plan
    path: ./plan
```

and, when the apply is a separate job, on the job itself — a step's outputs do
not cross a job boundary, so the plan job has to publish one:

```yaml
jobs:
  plan:
    outputs:
      destructive: ${{ steps.plan.outputs.destructive }}
    steps:
      - id: plan
        uses: arcanyx-pub/pgpushy-action@v1
        with: { command: plan, version: 0.3.2, env: prod, on-destructive: continue }

  apply:
    needs: plan
    if: github.event_name == 'push' && needs.plan.outputs.destructive != 'true'
```

Use `continue-on-error: true` for the other half: reading `exit-code` after a
run that **failed**, a refusal included. Without it a failed step skips every
later step by its implicit `success()`, and there is nothing left to read the
outputs:

```yaml
- id: plan
  continue-on-error: true
  uses: arcanyx-pub/pgpushy-action@v1
  with: { command: plan, version: 0.3.2, env: prod }

- if: steps.plan.outputs.exit-code == '1'
  run: echo "pgpushy refused this plan; the tree is the problem, not the database"
```

What `continue-on-error` cannot do is tell those two apart — it swallows a
refused plan and a destructive one alike, and spec §9.1 makes them route to
different people. That is the whole reason `on-destructive` exists.

## Credentials

pgpushy takes its target from the named environment and **not** from the
ambient `PG*` variables: the whole purpose of `--env prod` is to name a target
unambiguously, and a stray `PGHOST` that silently redirected it would defeat
that at exactly the moment it matters. The password is the one exception,
because a secret does not belong in a version-controlled file:

```yaml
env:
  PGPASSWORD: ${{ secrets.DB_DEPLOY_PASSWORD }}
```

Approval is GitHub's, not pgpushy's. `apply` always passes `--auto-approve`,
and there is no input to turn that off: standard input is never a terminal in
Actions, so pgpushy would refuse the run outright, and the approval this shape
relies on is the required reviewers on the job's `environment:` — which have
already answered by the time the job is allowed to start.

### Secrets

The action registers `PGPASSWORD` and `PGPUSHY_PLAN_PASSWORD` with the runner's
log masker for the rest of the job. A value from `secrets.*` is masked already;
the one this covers is a password **minted during the run** — an OIDC exchange,
an RDS auth token, anything a step computed rather than stored — which no
secret store ever saw and therefore no secret store masks. Steps that ran
before this action are not covered, and a value under eight characters is left
alone: the runner redacts every occurrence of a masked string anywhere in the
log, so masking a short one would black out unrelated text.

That last part is inherent, not a threshold. A password that happens to equal
an identifier — an environment name, a schema, a table — blacks out that word
wherever the runner redacts: the job log, and the step summary, which the
runner scrubs before it uploads it. A plan reading `DROP TABLE ***.orders` in
the summary is the masker working as designed, and the fix is a password that
is not also a word the schema uses. The pull-request comment is the exception,
and not a reassuring one: it is posted through the API rather than written to
the log, so it is never scrubbed, and a plan that quotes a masked value quotes
it in full there.

## Never use this with `pull_request_target`

`pull_request_target` runs the base branch's workflow with the repository's
secrets and a write token, and is the standard way to give a fork's pull
request more privilege than it should have. Combining it with a checkout of
the pull request's head would be worse here than in most actions, because
`pgpushy.toml` is two things at once:

- a **target-redirection surface** — `[env.*] host`, `port` and `db` name the
  database this action connects to, with whatever `PGPASSWORD` is in scope;
- a **code-execution surface** — `[[generate]] command` is an argv this action
  executes verbatim on `generate-check`.

Both are read out of the tree, which is what makes them right for a
same-repository branch and wrong for an untrusted one. Use `pull_request`. The
action refuses to comment on any other event for the same reason.

## The destructive gate

`plan` exits **2** when the plans are valid and would apply, but contain
destructive changes the environment does not permit. That is deliberately not
`1`: a broken source tree and a dropped column route to different people.

There is **no `allow_destructive` input**, because there is no flag either.
Destructive tolerance is a property of the target — a development database
says yes, production says no — so it lives per environment in `pgpushy.toml`:

```toml
[env.dev]
db                = "shop_dev"
user              = "dev"
allow_destructive = true
```

A flag that disabled a safety check per invocation is the hazard that
configuration exists to prevent, so the remedy for a blocked plan is a
reviewed change to that file. On the push path, the consequence is the useful
one: a destructive plan fails the plan job, and the gated apply job never runs.

`destructive` is a fact about the plan, not about whether the run was allowed
to proceed — an environment with `allow_destructive = true` exits 0 and still
reports `true`.

`on-destructive: continue` permits nothing in pgpushy — it still exits 2, the
artifact still records every drop, and nothing is applied — but it **does**
give up the paragraph above. A plan job that succeeds is a plan job whose
artifact uploads and whose `needs:` dependents run, so the workflow has to
re-state the gate on the `destructive` output, on the upload and on the apply
job, as [Outputs](#outputs) shows. That is the trade the input offers: the
finding becomes data the workflow routes on, and routing it is then the
workflow's job.

## Permissions

`comment: true` needs `pull-requests: write` on the job. If the token cannot
write, the action prints the API error and fails the step rather than quietly
posting nothing. A pull request from a fork gets a read-only token whatever
the workflow asks for, so a workflow that runs on fork pull requests should
make `comment` conditional on the head repository.

Nothing else this action does needs a permission beyond `contents: read`.

## The comment

One comment per environment, edited in place: a schema pull request that gets
ten pushes should carry one plan, not ten. The comment is found by a hidden
marker — `<!-- pgpushy-action plan env=<name> -->` — so two environments
planned on the same pull request keep two comments, because they are two
different answers. The headline states the outcome, destructive steps are
listed by kind and path, and the full plan sits in a `<details>` block,
truncated if it would not fit in a GitHub comment.

On any event but `pull_request`, `comment: true` prints a notice saying it has
nowhere to post and does nothing else. Only comments this action wrote are
edited — the marker is visible in any comment's source, so a plain match on it
would let a pull request author capture the plan under their own name.

## The step summary

Every `plan` also writes that body — the same headline, the same destructive
list, the same plan output, without the hidden marker — to the run's
[job summary](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#adding-a-job-summary).
There is no input for it. A run on a push or a schedule has no pull request to
comment on, and its plan would otherwise be readable only by opening the job
and scrolling the log; on the summary page it is the first thing under the run.
The comment's truncation applies unchanged: a step summary may be 1 MiB where a
comment may be 64 KB, but one budget means the two are the same plan, and a
plan that overruns 60 KB is one to read in the artifact rather than in either.
The one difference is not this action's doing: the runner scrubs the summary
through the secret masker before uploading it, and the comment goes out through
the API unscrubbed, so a plan quoting a masked value reads `***` in the summary
and reads the value in the comment.

## Versioning

Pin the action to the moving major tag and pgpushy to an exact version:

```yaml
uses: arcanyx-pub/pgpushy-action@v1
with:
  version: 0.3.2
```

`v1` moves as this action changes and will not break its inputs; `version`
pins the tool, so a pgpushy release never changes what a repository's schema
runs do until someone edits that line.

### One version, many workflows

`version` is required on every step, which in a workflow with a plan job and an
apply job means writing it twice — and a bump that updates one of them plans
with one program and applies with another. Put it in a workflow-level `env:`
and reference it:

```yaml
env:
  PGPUSHY_VERSION: "0.3.2"

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: arcanyx-pub/pgpushy-action@v1
        with:
          command: plan
          version: ${{ env.PGPUSHY_VERSION }}
```

Across several workflows, a [repository variable](https://docs.github.com/en/actions/learn-github-actions/variables)
does the same job for all of them: `version: ${{ vars.PGPUSHY_VERSION }}`, and
a bump is one edit in the repository's settings. This action's own CI takes the
first form — one `env:` at the top of `ci.yml`, read by every job.

## Platforms

Linux and macOS, amd64 and arm64 — the platforms pgpushy publishes binaries
for, which are the platforms pgschema publishes binaries for. There is no
Windows binary, and the action says so rather than failing on a 404.

The binary is downloaded from the pgpushy release, verified against the
release's `SHA256SUMS`, and cached under `RUNNER_TOOL_CACHE` by version and
platform. A cache hit is re-verified rather than trusted for being present:
that is what pgpushy itself does for pgschema, and a downloaded-and-executed
binary in CI is a supply-chain step whether or not anyone calls it one.

pgschema is not cached by the action. pgpushy downloads and verifies it on the
first run that needs a target, into `~/.cache/pgpushy`, and measured on hosted
runners a plan takes the same time with and without that fetch already done:
GitHub's release CDN is as fast as a cache restore, so a cache step would add
a post-job step and a failure mode and save nothing.

## What the runner has to have

`jq` and `gh` are both used: `jq` reads the plan artifact's `summary.json` and
builds the comment payload, and `gh` posts the comment. Every GitHub-hosted
runner carries both. A self-hosted runner must install them — the action
checks for them up front and says which is missing rather than failing later.

github.com only. The comment is posted through `gh api`, which targets
github.com; GitHub Enterprise Server is out of scope.

## License

Apache-2.0. See [LICENSE](LICENSE).
