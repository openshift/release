#!/bin/bash
set -euo pipefail

if [[ -z "${AZURE_REGION_OVERRIDE}" ]]; then
  echo "AZURE_REGION_OVERRIDE not set; leaving install-config.yaml region as leased (${LEASED_RESOURCE})"
  echo "${LEASED_RESOURCE}" > "${SHARED_DIR}/azure-region"
  exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
echo "Overriding Azure region from leased '${LEASED_RESOURCE}' to '${AZURE_REGION_OVERRIDE}'"
/tmp/yq eval ".platform.azure.region = \"${AZURE_REGION_OVERRIDE}\"" -i "${CONFIG}"
echo "${AZURE_REGION_OVERRIDE}" > "${SHARED_DIR}/azure-region"
