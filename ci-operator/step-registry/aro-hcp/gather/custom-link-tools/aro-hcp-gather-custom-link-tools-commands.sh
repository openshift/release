#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Temporary: support both pre- and post- binaries for PR
#            https://github.com/Azure/ARO-HCP/pull/4181/
# The new binary requires --rendered-config; passing it to the old binary breaks.
if test/aro-hcp-tests custom-link-tools --help 2>&1 | grep -q -- '--rendered-config'; then
  test/aro-hcp-tests custom-link-tools \
    --timing-input "${SHARED_DIR}" \
    --output "${ARTIFACT_DIR}/" \
    --rendered-config "${SHARED_DIR}/config.yaml"
else
  test/aro-hcp-tests custom-link-tools \
    --timing-input "${SHARED_DIR}" \
    --output "${ARTIFACT_DIR}/"
fi
