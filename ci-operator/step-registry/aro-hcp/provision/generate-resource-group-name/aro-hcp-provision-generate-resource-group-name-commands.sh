#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

# Function to generate random string
generate_random_string() {
    local char_set='a-zA-Z0-9'

    head -c 100 /dev/urandom | tr -dc "${char_set}" | head -c 6
}

# Generate resource group name
RANDOM_SUFFIX="$(generate_random_string)"
RESOURCE_GROUP_NAME="${CUSTOMER_RESOURCE_GROUP_PREFIX}-${RANDOM_SUFFIX}"

echo "${RESOURCE_GROUP_NAME}" > "${SHARED_DIR}/customer-resource-group-name.txt"
