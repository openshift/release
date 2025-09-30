#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# use login script from the aro-hcp-provision-azure-login step
"${SHARED_DIR}/az-login.sh"

export CUSTOMER_RG_NAME; CUSTOMER_RG_NAME=$(cat "${SHARED_DIR}/customer-resource-group-name.txt")

az deployment group create \
  --name 'node-pool' \
  --subscription "${SUBSCRIPTION}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --template-file demo/bicep/nodepool.bicep \
  --parameters \
    clusterName="${CLUSTER_NAME}" \
    nodePoolName="${NP_NAME}"
