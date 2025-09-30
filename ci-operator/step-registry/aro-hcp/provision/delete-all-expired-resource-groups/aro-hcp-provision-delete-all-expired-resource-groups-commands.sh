#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

unset GOFLAGS
make -C test/

# use login script from the aro-hcp-provision-azure-login step
"${SHARED_DIR}/az-login.sh"

set -x # Turn on command tracing

CUSTOMER_SUBSCRIPTION="${SUBSCRIPTION}" ./test/aro-hcp-tests delete-expired-resource-groups
