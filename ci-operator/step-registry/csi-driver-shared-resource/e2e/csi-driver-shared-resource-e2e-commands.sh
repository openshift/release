#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs an e2e suite for the Shared Resource CSI driver
# The suite assumes that the CSI driver has been deployed to the cluster.
# 
# The KUBECONFIG environment variable must be set for the step to run to full completion.
#
# The command utilizes two environment variables:
#
# - TEST_SUITE: The test suite to run. Defaults to "normal", can also be "disruptive" and "slow".
# - TEST_TIMEOUT: The test suite to run. Defaults to "30m", can be any parsable duration.

echo "Starting step csi-driver-shared-resource-e2e."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping e2e test of csi-driver-shared-resource."
    exit 0
fi

suite=${TEST_SUITE:-"normal"}
timeout=${TEST_TIMEOUT:-"30m"}

echo "Starting e2e test suite ${suite} with timeout ${timeout}."
make test-e2e-no-deploy TEST_SUITE="${suite}" TEST_TIMEOUT="${timeout}"
echo "Finished e2e test suite ${suite}."

echo "Step csi-driver-shared-resource-e2e completed."
