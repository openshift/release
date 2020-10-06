#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
TFVARS_PATH=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${TFVARS_PATH})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${TFVARS_PATH})
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
  platform:
    vsphere:
      osDisk:
        diskSizeGB: 120
compute:
- name: "worker"
  replicas: 3
  platform:
    vsphere:
      cpus: 4
      coresPerSocket: 1
      memoryMB: 16384
      osDisk:
        diskSizeGB: 120
platform:
  vsphere:
    vcenter: "vcenter.sddc-44-236-21-251.vmwarevmc.com"
    datacenter: SDDC-Datacenter
    defaultDatastore: WorkloadDatastore
    cluster: "Cluster-1"
    network: "${LEASED_RESOURCE}"
    password: ${vsphere_password}
    username: ${vsphere_user}
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
EOF
