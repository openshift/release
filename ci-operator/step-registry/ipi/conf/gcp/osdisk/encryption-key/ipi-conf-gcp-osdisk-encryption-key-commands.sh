#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${KMS_KEY_RING}" == "" ]] || [[ "${KMS_KEY_RING_LOCATION}" == "" ]] || [[ "${KMS_KEY_NAME}" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Invalid OS disk custom encryption settings, abort." && exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

project_id="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
if [[ "${KMS_KEY_RING_PROJECT_ID}" != "" ]]; then
  project_id="${KMS_KEY_RING_PROJECT_ID}"
fi
service_account=$(jq -r .client_email ${CLUSTER_PROFILE_DIR}/gce.json)
if [[ "${KMS_KEY_SERVICE_ACCOUNT}" != "" ]]; then
  service_account="${KMS_KEY_SERVICE_ACCOUNT}"
fi

cat > "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      osDisk:
        encryptionKey:
          kmsKey:
            keyRing: ${KMS_KEY_RING}
            location: ${KMS_KEY_RING_LOCATION}
            name: ${KMS_KEY_NAME}
            projectID: ${project_id}
          kmsKeyServiceAccount: ${service_account}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated platform.gcp.defaultMachinePlatform.osDisk.encryptionKey in '${CONFIG}'."

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
