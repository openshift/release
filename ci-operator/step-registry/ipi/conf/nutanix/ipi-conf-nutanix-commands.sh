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

BASE_DOMAIN=$(<"${SHARED_DIR}"/basedomain.txt)

source "${SHARED_DIR}/nutanix_context.sh"

RHCOS_PATCH=""
if [[ ! -z "${OVERRIDE_RHCOS_IMAGE}" ]]; then
    RHCOS_PATCH=$(printf "\n    ClusterOSImage: %s" "${OVERRIDE_RHCOS_IMAGE}")
fi

if [[ "${SIZE_VARIANT}" == "compact" ]]; then
    MACHINE_POOL_OVERRIDES="
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 3
  platform:
    nutanix:
      cpus: 8
      memoryMiB: 32768
      osDisk:
        diskSizeGiB: 120"
else
    MACHINE_POOL_OVERRIDES="
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    nutanix:
      cpus: 4
      coresPerSocket: 1
      memoryMiB: 16384
      osDisk:
        diskSizeGiB: 120
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3"
fi

echo "$(date -u --rfc-3339=seconds) - Adding platform data to install-config.yaml"

# Populate install-config with Nutanix specifics
cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
credentialsMode: Manual
platform:
  nutanix:${RHCOS_PATCH}
    apiVIP: ${API_VIP}
    ingressVIP: ${INGRESS_VIP}
    prismCentral:
      endpoint:
        address: ${NUTANIX_HOST}
        port: ${NUTANIX_PORT}
      password: ${NUTANIX_PASSWORD}
      username: ${NUTANIX_USERNAME}
    prismElements:
    - endpoint:
        address: ${PE_HOST}
        port: ${PE_PORT}
      uuid: ${PE_UUID}
    subnetUUIDs:
    - ${SUBNET_UUID}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
$MACHINE_POOL_OVERRIDES
EOF
