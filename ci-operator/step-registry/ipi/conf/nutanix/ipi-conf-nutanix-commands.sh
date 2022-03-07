#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Failed to acquire lease"
    exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

source "${SHARED_DIR}/nutanix_context.sh"

echo "$(date -u --rfc-3339=seconds) - Adding platform data to install-config.yaml"

# Populate install-config with Nutanix specifics
cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
credentialsMode: Manual
platform:
  nutanix:
    apiVIP: ${API_VIP}
    ingressVIP: ${INGRESS_VIP}
    password: ${NUTANIX_PASSWORD}
    port: ${NUTANIX_PORT}
    prismCentral: ${NUTANIX_HOST}
    prismElementUUID: ${PE_UUID}
    subnetUUID: ${SUBNET_UUID}
    username: ${NUTANIX_USERNAME}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
EOF