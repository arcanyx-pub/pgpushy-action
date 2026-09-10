#!/usr/bin/env bash
#
# Delete the files a minted password passed through, whatever happened.
#
# The step that runs pgpushy reads each file into its own environment and
# deletes it there, which is the ordinary path and covers a pgpushy that
# failed. This is the other paths: a step between the mint and the run that
# failed — the install, say — leaves every later step skipped, and a file
# holding a live credential would then sit in the runner's temp directory for
# the rest of the job. So this runs on `always()`, last, and deleting a file
# that is already gone is the expected case rather than a problem.

set -euo pipefail

: "${PASSWORD_FILE:=}" "${PLAN_PASSWORD_FILE:=}"

[ -z "$PASSWORD_FILE" ] || rm -f "$PASSWORD_FILE"
[ -z "$PLAN_PASSWORD_FILE" ] || rm -f "$PLAN_PASSWORD_FILE"
