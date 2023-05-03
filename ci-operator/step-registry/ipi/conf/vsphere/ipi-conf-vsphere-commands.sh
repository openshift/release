#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_url
declare vsphere_cluster
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

CONFIG="${SHARED_DIR}/install-config.yaml"
STATIC_IPS="${SHARED_DIR}"/static-ip-hosts.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

MACHINE_POOL_OVERRIDES=""
RESOURCE_POOL_DEF=""
set +o errexit
VERSION=$(echo "${JOB_NAME}" | grep -o -E '4\.[0-9]+')
set -o errexit

if [ ! -z ${VERSION} ]; then
    Z_VERSION=$(echo ${VERSION} | cut -d'.' -f2)
    if [ ${Z_VERSION} -gt 9 ]; then
        echo "4.x installation is later than 4.9, will install with resource pool"
        RESOURCE_POOL_DEF="resourcePool: /${vsphere_datacenter}/host/${vsphere_cluster}/Resources/ipi-ci-clusters"
    fi
    if [ ${Z_VERSION} -lt 11 ]; then
      MACHINE_POOL_OVERRIDES="controlPlane:
  name: master
  replicas: 3
  platform:
    vsphere:
      osDisk:
        diskSizeGB: 120
compute:
- name: worker
  replicas: 3
  platform:
    vsphere:
      cpus: 4
      coresPerSocket: 1
      memoryMB: 16384
      osDisk:
        diskSizeGB: 120"
    fi
fi

if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        echo "Compact SIZE_VARIANT was configured, setting worker's replicas to 0"
        MACHINE_POOL_OVERRIDES="controlPlane:
  name: master
  replicas: 3
  platform:
    vsphere:
      cpus: 8
      memoryMB: 32768
      osDisk:
        diskSizeGB: 120
compute:
- name: worker
  replicas: 0"
fi

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
$MACHINE_POOL_OVERRIDES
platform:
  vsphere:
    vcenter: "${vsphere_url}"
    datacenter: "${vsphere_datacenter}"
    defaultDatastore: "${vsphere_datastore}"
    cluster: "${vsphere_cluster}"
    network: "${LEASED_RESOURCE}"
    password: "${GOVC_PASSWORD}"
    username: "${GOVC_USERNAME}"
    ${RESOURCE_POOL_DEF}
EOF

if [ -f ${SHARED_DIR}/external_lb ]; then 
  echo "$(date -u --rfc-3339=seconds) - external load balancer in use, not setting VIPs"
else
cat >> "${CONFIG}" << EOF
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
EOF
fi

if [ -f ${STATIC_IPS} ]; then
  echo "$(date -u --rfc-3339=seconds) - static IPs defined, appending to platform spec"
  cat ${STATIC_IPS} >> ${CONFIG}
fi

cat >> "${CONFIG}" << EOF
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF
