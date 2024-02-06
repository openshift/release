#!/bin/bash
export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-e2e-test"
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
echo "COLLECTION_METHOD=${COLLECTION_METHOD:-}"
exec .openshift-ci/dispatch.sh "${job}"
