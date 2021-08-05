#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs an e2e suite for the Shared Resource CSI driver
# The suite assumes that the CSI driver prerequisites have been deployed to the cluster.
# However, the test runs its own deployment of the driver.
# 
# The KUBECONFIG environment variable must be set for the step to run to full completion.
#
# The command utilizes two environment variables:
#
# - DRIVER_IMAGE: The driver image to deploy. Defaults to the latest origin upstream image.
# - TEST_SUITE: The test suite to run. Defaults to "normal", can also be "disruptive" and "slow".

echo "Starting step csi-driver-shared-resource-e2e."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping e2e test of csi-driver-shared-resource."
    exit 0
fi

image=${DRIVER_IMAGE:-"quay.io/openshift/origin-csi-driver-shared-resource:latest"}
suite=${TEST_SUITE:-"normal"}

echo "Starting e2e test suite ${suite} with driver image ${image}."
KUBERNETES_CONFIG=${KUBECONFIG} IMAGE_NAME=${image} go test -race -count 1 -tags "${suite}" -timeout 30m -v ./test/e2e/...
echo "Finished e2e test suite ${suite}."

echo "Step csi-driver-shared-resource-e2e completed."
