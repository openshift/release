#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cd /go/src/github.com/openshift/aws-ebs-csi-driver-operator
cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

# Temporary hack to postpone openshift-test startup by few minutes to de-flake
# https://bugzilla.redhat.com/show_bug.cgi?id=1890131
# TODO(jsafrane): remove in a few days (weeks)
# Get a random number between 0-2.
SLEEP_MINUTES=$( shuf -i 0-2 -n 1 )
SLEEP_SECONDS=$[ $SLEEP_MINUTES * 60 ]
echo POSTPONING TESTS BY: $SLEEP_SECONDS
sleep $SLEEP_SECONDS

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
