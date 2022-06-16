#!/bin/bash
exec .openshift-ci/dispatch.sh "${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
