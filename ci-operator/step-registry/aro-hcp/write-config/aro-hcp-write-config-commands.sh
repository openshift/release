#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

if [[ -f "${SHARED_DIR}/config.yaml" || -f "${SHARED_DIR}/config.yaml.gz" ]]; then
  echo "config.yaml already exists in SHARED_DIR, skipping generation"
  exit 0
fi

declare -A shortlocation_map=(
  ["australiaeast"]="au"
  ["brazilsouth"]="br"
  ["canadacentral"]="ca"
  ["westeurope"]="eu"
  ["centralindia"]="in"
  ["uksouth"]="uk"
  ["switzerlandnorth"]="sz"
  ["eastus2"]="us"
  ["westus3"]="us"
)
declare -A env_map=(
  ["integration/parallel"]="int"
  ["stage/parallel"]="stg"
  ["prod/parallel"]="prod"
)
declare -A kusto_map=(
  ["dev"]="dev"
  ["int"]="int"
  ["stg"]="prod"
  ["prod"]="prod"
)

SHORT_LOCATION="${shortlocation_map[$LOCATION]:-unknown}"
JOB_ENV="${env_map[$ARO_HCP_SUITE_NAME]:-dev}"
KUSTO_ENV="${kusto_map[$JOB_ENV]}"

KUSTO_NAME="hcp-${KUSTO_ENV}-${SHORT_LOCATION}"
MGMT_NAME="${JOB_ENV}-${LOCATION}-mgmt-1"
SVC_NAME="${JOB_ENV}-${LOCATION}-svc"

cat > "${SHARED_DIR}/config.yaml" <<EOF
global:
  region: ${LOCATION}
kusto:
  kustoName: ${KUSTO_NAME}
svc:
  aks:
    name: ${SVC_NAME}
mgmt:
  aks:
    name: ${MGMT_NAME}
EOF
