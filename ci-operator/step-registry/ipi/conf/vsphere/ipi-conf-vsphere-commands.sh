#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
TFVARS_PATH=/var/run/secrets/ci.openshift.io/cluster-profile/secret.auto.tfvars
vsphere_user=$(grep -oP 'vsphere_user="\K[^"]+' ${TFVARS_PATH})
vsphere_password=$(grep -oP 'vsphere_password="\K[^"]+' ${TFVARS_PATH})
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
platform:
  vsphere:
    cluster: devel
    datacenter: dc1
    defaultDatastore: nvme-ds1
    network: VM Network
    password: ${vsphere_password}
    username: ${vsphere_user}
    vCenter: vcsa-ci.vmware.devcluster.openshift.com
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
EOF
