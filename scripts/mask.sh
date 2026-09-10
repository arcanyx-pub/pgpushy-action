#!/usr/bin/env bash
#
# Register the database passwords with the runner's log masker, for the rest
# of the job.
#
# pgpushy reads two passwords from the environment and nothing else: PGPASSWORD
# for the target, and PGPUSHY_PLAN_PASSWORD for an external plan database, which
# is a separate server with separate credentials (spec §10.4). A secret that
# came from `secrets.*` is masked already; one minted during the run — a token
# from an OIDC exchange, an RDS auth token, anything a job computed rather than
# stored — is not, because no secret store ever saw it. Masking here covers both
# without the caller having to know which kind it has.
#
# This covers what the job already had in its environment when the action
# started. A password the action mints itself is masked by mint.sh, at the
# moment it comes into existence, with the same function.
#
# This runs early, before the binary is fetched and before anything connects,
# so that everything the action itself logs is already covered.

set -euo pipefail

# shellcheck source=scripts/mask-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/mask-lib.sh"

: "${PGPASSWORD:=}" "${PGPUSHY_PLAN_PASSWORD:=}"

mask PGPASSWORD "$PGPASSWORD"
mask PGPUSHY_PLAN_PASSWORD "$PGPUSHY_PLAN_PASSWORD"
