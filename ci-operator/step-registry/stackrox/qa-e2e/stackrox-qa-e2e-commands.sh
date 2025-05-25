#!/bin/bash
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
git clone https://github.com/stackrox/stackrox.git
cd stackrox
exec .openshift-ci/dispatch.sh "${job}"
