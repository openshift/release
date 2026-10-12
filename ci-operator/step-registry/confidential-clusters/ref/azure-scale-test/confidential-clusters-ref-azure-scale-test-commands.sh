#!/bin/bash
set -euo pipefail

SUFFIX=$(cat "${SHARED_DIR}/cocl-suffix")
AZURE_RESOURCE_ID=$(cat "${SHARED_DIR}/cocl-azure-resource-id")
APPROVED_IMAGE=$(cat /tmp/secrets/azure-qe/cocl-approved-image)

# Reads one of bundle/update-bundle.sh's hardcoded "export VAR=..." image
# pullspecs without sourcing the script itself (sourcing it would also run
# its manifest/bundle generation side effects).
bundle_image() {
  sed -n 's/^export '"${1}"'="\(.*\)"$/\1/p' bundle/update-bundle.sh
}
# Not live yet: those pullspecs are the latest Konflux-nudged Red Hat catalog
# digests, not what this repo's own CI just built from this PR, so using them
# wouldn't actually exercise the code under test. Once CI-built images are
# pushed and update-bundle.sh is wired to reference them, drop REGISTRY/TAG
# below in favor of:
# OPERATOR_IMAGE=$(bundle_image OPERATOR_IMAGE)
# RELATED_IMAGE_TRUSTEE=$(bundle_image TRUSTEE_IMAGE)
# RELATED_IMAGE_REGISTRATION_SERVER=$(bundle_image REG_SERVER_IMAGE)
# RELATED_IMAGE_ATTESTATION_KEY_REGISTER=$(bundle_image ATTESTATION_KEY_REGISTER_IMAGE)
# RELATED_IMAGE_COMPUTE_PCRS=$(bundle_image COMPUTE_PCRS_IMAGE)

cd tests
make \
  TEST_NAMESPACE_PREFIX="scale-test-${SUFFIX}" \
  VIRT_PROVIDER=azure \
  AZURE_RESOURCE_ID="${AZURE_RESOURCE_ID}" \
  APPROVED_IMAGE="${APPROVED_IMAGE}" \
  REGISTRY=quay.io/jnaucke \
  TAG=20261006-main-7aee09d \
  scale-tests
