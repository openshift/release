#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

${RESOURCEGROUP:=$(cat "${SHARED_DIR}/resourcegroup")}
${CLUSTER:=$(cat "${SHARED_DIR}/cluster-name")}

echo "Deleting ARO cluster ${CLUSTER}"

az aro delete --yes --name="${CLUSTER}" --resource-group="${RESOURCEGROUP}"
az group delete --yes --name="${RESOURCEGROUP}"