#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# use login script from the aro-hcp-provision-azure-login step
/bin/bash "${SHARED_DIR}/az-login.sh"

# iterate over every tracked resource group
ls -al "${SHARED_DIR}"/
for file in "${SHARED_DIR}"/tracked-resource-group_*; do
    if [ -f "$file" ]; then
        full_filename=$(basename "$file")
        resource_group_name=${full_filename#tracked-resource-group_}

        # Delete each resource group
        az group delete --subscription "${SUBSCRIPTION}" --yes --name "${resource_group_name}" || true
    fi
done
