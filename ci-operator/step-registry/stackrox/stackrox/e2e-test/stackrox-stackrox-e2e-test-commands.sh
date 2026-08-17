#!/bin/bash

# Redirect BASH_ENV to a writable temp for this step. The CI image sets BASH_ENV
# to a root-owned file that the arbitrary non-root UID used by Prow/OpenShift
# cannot write, so cci-export() spams "Permission denied" on every bash call.
BASH_ENV="$(mktemp)"
export BASH_ENV
export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-e2e-test"
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
exec .openshift-ci/dispatch.sh "${job}"
