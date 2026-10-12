#!/bin/bash
export OPENSHIFT_CI_STEP_NAME="stackrox-e2e"
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
exec .openshift-ci/dispatch.sh "${job}"
