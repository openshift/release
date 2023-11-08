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

function kata_containers_msg() {
    echo
    echo
    echo "error: ---< kata-containers CI >---"
    echo "error: Overriding exit code because: $*"
    echo "error: Previous exit code was: $RET"
    echo "error: ---< END kata-containers CI >---"
    echo
    echo
}

OUT=$(/usr/bin/openshift-tests-original $@ 2>&1)
RET=$?

echo "$OUT"

[ "$RET" -eq 0 ] && exit 0

# Only report failure on actual test failures (ignore invariants)
if [[ "$OUT" =~ "error: failed because an invariant was violated" ]]; then
    kata_containers_msg "invariant was violated"
    exit 0
elif [[ "$OUT" =~ "error: failed due to a MonitorTest failure" ]]; then
    kata_containers_msg "MonitorTest failure"
    exit 0
fi
exit "$RET"
