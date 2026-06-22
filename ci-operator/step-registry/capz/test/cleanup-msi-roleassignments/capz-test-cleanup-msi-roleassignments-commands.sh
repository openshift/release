#!/bin/bash
set -o nounset
set -o pipefail

source "${SHARED_DIR}/capz-test-env.sh"

if [[ -z "${MSI_RESOURCEGROUPNAME:-}" ]]; then
  echo "[cleanup-msi-ra] No MSI_RESOURCEGROUPNAME set, skipping"
  exit 0
fi

echo "[cleanup-msi-ra] Cleaning up RoleAssignments in MSI RG: ${MSI_RESOURCEGROUPNAME}"

{ set +o xtrace; } 2>/dev/null
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

RA_IDS=$(az role assignment list \
  --resource-group "${MSI_RESOURCEGROUPNAME}" \
  --query "[].id" \
  --output tsv 2>/dev/null) || true

if [[ -z "${RA_IDS}" ]]; then
  echo "[cleanup-msi-ra] No RoleAssignments found in ${MSI_RESOURCEGROUPNAME}"
  exit 0
fi

COUNT=$(echo "${RA_IDS}" | wc -l)
echo "[cleanup-msi-ra] Found ${COUNT} RoleAssignment(s) to delete"

FAILED=0
while IFS= read -r ra_id; do
  [[ -z "${ra_id}" ]] && continue
  echo "[cleanup-msi-ra] Deleting: ${ra_id}"
  if ! az role assignment delete --ids "${ra_id}" --output none 2>/dev/null; then
    echo "[cleanup-msi-ra] WARNING: Failed to delete ${ra_id} (may already be gone)"
    FAILED=$((FAILED + 1))
  fi
done <<< "${RA_IDS}"

if [[ ${FAILED} -gt 0 ]]; then
  echo "[cleanup-msi-ra] ${FAILED} deletion(s) failed (non-fatal)"
fi
echo "[cleanup-msi-ra] Cleanup complete"
