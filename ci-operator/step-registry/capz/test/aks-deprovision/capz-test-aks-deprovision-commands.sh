#!/usr/bin/env bash
set -euo pipefail

source openshift-ci/capz-test-env.sh

if [[ ! -f "${SHARED_DIR}/resourcegroup_aks" ]]; then
  echo "No resourcegroup_aks file found, nothing to clean up"
  exit 0
fi

{ set +o xtrace; } 2>/dev/null
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
echo "Deleting resource group ${RESOURCEGROUP}"
az group delete --name "${RESOURCEGROUP}" --yes
