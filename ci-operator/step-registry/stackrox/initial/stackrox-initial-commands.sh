#!/bin/bash
set -vex
echo 'info: test executing initial commands.sh'
exec .openshift-ci/dispatch.sh "${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
