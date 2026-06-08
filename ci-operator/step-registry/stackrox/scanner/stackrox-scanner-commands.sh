#!/bin/bash
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#hourly-}"
job="${job#nightly-}"
exec .openshift-ci/dispatch.sh "${job}"
