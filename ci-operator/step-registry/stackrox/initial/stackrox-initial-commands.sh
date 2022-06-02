#!/bin/bash
echo 'error: test executing initial commands.sh'
exec .openshift-ci/dispatch.sh "${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
