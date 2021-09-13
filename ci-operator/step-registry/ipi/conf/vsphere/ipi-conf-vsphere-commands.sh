#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

vsphere_datacenter="SDDC-Datacenter"
vsphere_datastore="WorkloadDatastore"
vsphere_cluster="Cluster-1"
vsphere_url="vcenter.sddc-44-236-21-251.vmwarevmc.com"
VSPHERE_CLUSTER_LOCATION=VMC
TFVARS_PATH=/var/run/vault/vsphere/secret.auto.tfvars

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

# **testing** for IBM cloud, only run specific jobs on specific lease numbers
if [ $((${LEASED_RESOURCE//[!0-9]/})) -ge 88 ]; then     
  echo Scheduling job on IBM Cloud instance
  VSPHERE_CLUSTER_LOCATION=IBM
  TFVARS_PATH=/var/run/vault/ibmcloud/secret.auto.tfvars  
  vsphere_url="ibmvcenter.vmc-ci.devcluster.openshift.com"
  vsphere_datacenter="IBMCloud"
  vsphere_cluster="vcs-ci-workload"
  vsphere_datastore="vsanDatastore"
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${TFVARS_PATH})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${TFVARS_PATH})
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)
echo "${VCENTER_CLUSTER_LOCATION}" > "${SHARED_DIR}/vsphere_cluster_location"

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
    vcenter: "${vsphere_url}"
    datacenter: "${vsphere_datacenter}"
    defaultDatastore: "${vsphere_datastore}"
    cluster: "${vsphere_cluster}"
    network: "${LEASED_RESOURCE}"
    password: "${vsphere_password}"
    username: "${vsphere_user}"
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF
