#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

unset GOFLAGS
make -C test/

# use login script from the aro-hcp-provision-azure-login step
/bin/bash "${SHARED_DIR}/az-login.sh"

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

CUSTOMER_SUBSCRIPTION="${SUBSCRIPTION}" ./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" --junit-path="${ARTIFACT_DIR}/junit.xml"
