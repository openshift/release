#!/bin/bash
set -euo pipefail

# hcpctl is built in-place by Containerfile.e2e (make build-hcpctl) and is not
# installed to a standard bin directory, so add its build output to PATH.
export PATH="${PWD}/tooling/hcpctl:${PATH}"

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

if [[ ! -f "${SHARED_DIR}/provision-complete" && ! -f "${SHARED_DIR}/provision-from-main-complete" ]]; then
  echo "Provisioning did not complete, skipping must-gather"
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/config.yaml" ]]; then
  echo "ERROR: config.yaml not found at ${SHARED_DIR}/config.yaml"
  exit 1
fi

KUSTO_NAME=$(yq '.kusto.kustoName' "${SHARED_DIR}/config.yaml")
KUSTO_REGION=$(yq '.kusto.location' "${SHARED_DIR}/config.yaml")

echo "KUSTO_NAME: ${KUSTO_NAME}"
echo "KUSTO_REGION: ${KUSTO_REGION}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

# Source the slot env to get CUSTOMER_SUBSCRIPTION — same as aro-hcp-test-local and
# aro-hcp-gather-snapshot, which both iterate per tracked resource group.
slot_env="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${slot_env}" ]]; then
  echo "ERROR: aro-hcp-slot.env not found at ${slot_env}"
  exit 1
fi
# shellcheck disable=SC1090
source "${slot_env}"

# Resolve subscription name to ID.
CUSTOMER_SUBSCRIPTION_ID=$(az account list --query "[?name=='${CUSTOMER_SUBSCRIPTION}'].id" -o tsv)
if [[ -z "${CUSTOMER_SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: failed to resolve CUSTOMER_SUBSCRIPTION='${CUSTOMER_SUBSCRIPTION}' to an ID"
  exit 1
fi
echo "CUSTOMER_SUBSCRIPTION_ID: ${CUSTOMER_SUBSCRIPTION_ID}"

# Collect tracked resource groups written by the E2E framework during the test phase.
# This is the same mechanism used by aro-hcp-deprovision-tracked-resource-groups and
# aro-hcp-gather-snapshot: each test writes a tracked-resource-group_<name> sentinel
# file to SHARED_DIR when it creates a resource group.
TRACKED_RGS=()
while IFS= read -r file; do
  rg_name=$(basename "${file}" | sed 's/^tracked-resource-group_//')
  TRACKED_RGS+=("${rg_name}")
done < <(find "${SHARED_DIR}" -maxdepth 1 -name "tracked-resource-group_*" 2>/dev/null | sort)

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"
mkdir -p "${MUST_GATHER_DIR}"

if [[ ${#TRACKED_RGS[@]} -eq 0 ]]; then
  echo "No tracked resource groups found in ${SHARED_DIR}, skipping must-gather"
  tar -czf "${ARTIFACT_DIR}/must-gather.tar.gz" -C "${ARTIFACT_DIR}" must-gather/ 2>/dev/null || true
  echo "must-gather.tar.gz written to ${ARTIFACT_DIR}"
  exit 0
fi

echo "Found ${#TRACKED_RGS[@]} tracked resource group(s): ${TRACKED_RGS[*]}"

TIMESTAMP_MIN=$(date -u -d '3 hours ago' '+%Y-%m-%d %H:%M:%S')

for tracked_rg in "${TRACKED_RGS[@]}"; do
  echo "Gathering must-gather for resource group: ${tracked_rg}"
  cluster_output="${MUST_GATHER_DIR}/${tracked_rg}"
  mkdir -p "${cluster_output}"

  if ! hcpctl must-gather query \
    --kusto "${KUSTO_NAME}" \
    --region "${KUSTO_REGION}" \
    --subscription-id "${CUSTOMER_SUBSCRIPTION_ID}" \
    --resource-group "${tracked_rg}" \
    --timestamp-min "${TIMESTAMP_MIN}" \
    --limit 2000 \
    --output-path "${cluster_output}"; then
    echo "WARNING: hcpctl must-gather query failed for resource group ${tracked_rg}, continuing"
  fi
done

echo "must-gather complete, compressing artifacts"
tar -czf "${ARTIFACT_DIR}/must-gather.tar.gz" -C "${ARTIFACT_DIR}" must-gather/
echo "must-gather.tar.gz written to ${ARTIFACT_DIR}"
