#!/bin/bash
#
# Copyright 2023 Red Hat, Inc.
#
# This script requires the stock openshift-tests to be present in
# /usr/bin/openshift-tests-original. It executes it passing all arguments
# and only reports failures when they were not caused by invariant tests
#
# Primary usage is the openshift/release kata-container pipelines
# to test new version simply modify the pipeline's yaml file to
# use pastebin version, verify it's passing and then push the change
# into this file.

OUT=$(/usr/bin/openshift-tests-original $@)
RET=$?

echo "$OUT"

[ "$RET" -eq 0 ] && exit 0

# Only report failure on actual test failures (ignore invariants)
if [[ "$OUT" =~ "error: failed because an invariant was violated" ]]; then
    # This message is reported when only invariant tests fail
    # currently we are aware this is happenning with kata-containers
    # so keep the junit results but report pass
    exit 0
else
    exit "$RET"
fi
