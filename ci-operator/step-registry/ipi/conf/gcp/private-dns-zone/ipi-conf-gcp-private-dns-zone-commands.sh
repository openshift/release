#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

CLUSTER_NAME=${NAMESPACE}-${UNIQUE_HASH}
CLUSTER_PVTZ_PROJECT="$(< ${SHARED_DIR}/cluster-pvtz-project)"

if [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "service-project" ]] || [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "host-project" ]]; then
  cat > "${PATCH}" << EOF
platform:
  gcp:
    privateDNSZone: 
      id: ${CLUSTER_NAME}-private-zone
      project: ${CLUSTER_PVTZ_PROJECT}
EOF
elif [[ "${PRIVATE_ZONE_PROJECT_TYPE}" == "third-project" ]]; then
  if [[ ! -f "${CLUSTER_PROFILE_DIR}/third_project_setting.json" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the 'third_project_setting.json' in CLUSTER_PROFILE_DIR, abort." && exit 1
  fi
  GCP_BASE_DOMAIN=$(jq -r '.baseDomain' "${CLUSTER_PROFILE_DIR}/third_project_setting.json")

  cat > "${PATCH}" << EOF
baseDomain: ${GCP_BASE_DOMAIN%.}
platform:
  gcp:
    privateZone: 
      zone: ${CLUSTER_NAME}-private-zone
      projectID: ${CLUSTER_PVTZ_PROJECT}
EOF
else
  echo "$(date -u --rfc-3339=seconds) - ERROR: Unknown private zone project type '${PRIVATE_ZONE_PROJECT_TYPE}', abort. " && exit 1
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated platform.gcp.privateDNSZone (or platform.gcp.privateZone) in '${CONFIG}'."

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
yq-go r "${CONFIG}" baseDomain
echo "(debug)--------------------"
