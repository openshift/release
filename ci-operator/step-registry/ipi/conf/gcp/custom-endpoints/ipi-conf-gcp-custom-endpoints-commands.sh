#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/gcp_custom_endpoint" ]; then
  echo "$(date -u --rfc-3339=seconds) - '${SHARED_DIR}/gcp_custom_endpoint' not found, nothing to do." && exit 0
fi
gcp_custom_endpoint=$(< "${SHARED_DIR}/gcp_custom_endpoint")

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/custom_endpoints.yaml.patch"
cat >> "${PATCH}" << EOF
platform:
  gcp:
    serviceEndpoints:
EOF

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_COMPUTE}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: Compute
      url: https://compute-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_CONTAINER}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: Container
      url: https://container-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_DNS}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: DNS
      url: https://dns-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_FILE}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: File
      url: https://file-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_IAM}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: IAM
      url: https://iam-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_SERVICEUSAGE}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: ServiceUsage
      url: https://serviceusage-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_CLOUDRESOURCEMANAGER}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: CloudResourceManager
      url: https://cloudresourcemanager-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

if [[ "${ENABLE_CUSTOM_ENDPOINT_FOR_STORAGE}" == "yes" ]]; then
  cat >> "${PATCH}" << EOF
    - name: Storage
      url: https://storage-${gcp_custom_endpoint}.p.googleapis.com
EOF
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" platform
rm "${PATCH}"
