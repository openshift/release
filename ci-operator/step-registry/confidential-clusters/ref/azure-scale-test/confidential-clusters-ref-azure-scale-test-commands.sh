#!/bin/bash
set -euo pipefail

AZURE_RESOURCE_ID=$(cat "${SHARED_DIR}/cocl-azure-resource-id")
APPROVED_IMAGE=$(cat /tmp/secrets/azure-qe/cocl-approved-image)
TEST_NAMESPACE_PREFIX="scale-test-$(cat "${SHARED_DIR}/cocl-suffix")"
export AZURE_RESOURCE_ID APPROVED_IMAGE TEST_NAMESPACE_PREFIX

export VIRT_PROVIDER=azure
# Lowest timeout is 1 minute, allow for one read timeout (5 minutes) retry
export TEST_TIMEOUT_MULTIPLIER=6
export INTEGRATION_TEST_THREADS=2

# Read an `export VAR=...` image spec without sourcing, from update-bundle.sh
bundle_image() {
  sed -n 's/^export '"${1}"'="\(.*\)"$/\1/p' bundle/update-bundle.sh
}
# TODO use these once ready, then drop REGISTRY+TAG below
# OPERATOR_IMAGE=$(bundle_image OPERATOR_IMAGE)
# RELATED_IMAGE_TRUSTEE=$(bundle_image TRUSTEE_IMAGE)
# RELATED_IMAGE_REGISTRATION_SERVER=$(bundle_image REG_SERVER_IMAGE)
# RELATED_IMAGE_ATTESTATION_KEY_REGISTER=$(bundle_image ATTESTATION_KEY_REGISTER_IMAGE)
# RELATED_IMAGE_COMPUTE_PCRS=$(bundle_image COMPUTE_PCRS_IMAGE)

(cd operator && git checkout 7aee09d)

echo "[INFO] Install cert-manager"
CRT_MGR_VERSION=$(cd operator && go list -m -f '{{.Version}}' github.com/cert-manager/cert-manager)
oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CRT_MGR_VERSION}/cert-manager.yaml"

cd tests
echo "[INFO] Running scale tests..."
make REGISTRY=quay.io/jnaucke TAG=20261006-main-7aee09d scale-tests
