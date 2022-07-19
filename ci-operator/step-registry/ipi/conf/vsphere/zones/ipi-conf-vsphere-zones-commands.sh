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
declare vsphere_url
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

declare -a vips
mapfile -t vips < "${SHARED_DIR}/vips.txt"

CONFIG="${SHARED_DIR}/install-config.yaml"
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
  platform:
    vsphere:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
compute:
- name: "worker"
  replicas: 4
  platform:
    vsphere:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
       - "us-west-1"
platform:
  vsphere:
    apiVIP: "${vips[0]}"
    ingressVIP: "${vips[1]}"
    vCenter: "${vsphere_url}"
    username: "${GOVC_USERNAME}"
    password: ${GOVC_PASSWORD}
    network: ${LEASED_RESOURCE}
    datacenter: "${vsphere_datacenter}"
    cluster: vcs-mdcnc-workload-1
    defaultDatastore: workload_share_vcsmdcncworkload_Yfyf6
    vcenters:
    - server: "${vsphere_url}"
      user: "${GOVC_USERNAME}"
      password: ${GOVC_PASSWORD}
      datacenters:
      - IBMCloud
      - datacenter-2
    deploymentZones:
    - name: us-east-1
      server: "${vsphere_url}"
      failureDomain: us-east-1
    - name: us-east-2
      server: "${vsphere_url}"
      failureDomain: us-east-2
    - name: us-east-3
      server: "${vsphere_url}"
      failureDomain: us-east-3
    - name: us-west-1
      server: "${vsphere_url}"
      failureDomain: us-west-1
    failureDomains:
    - name: us-east-1
      region:
        name: us-east
        type: Datacenter
        tagCategory: openshift-region
      zone:
        name: us-east-1a
        type: ComputeCluster
        tagCategory: openshift-zone
      topology:
        datacenter: "${vsphere_datacenter}"
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-1
        networks:
        - ${LEASED_RESOURCE}
        datastore: workload_share_vcsmdcncworkload_Yfyf6
    - name: us-east-2
      region:
        name: us-east
        type: Datacenter
        tagCategory: openshift-region
      zone:
        name: us-east-2a
        type: ComputeCluster
        tagCategory: openshift-zone
      topology:
        datacenter: "${vsphere_datacenter}"
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-2
        networks:
        - ${LEASED_RESOURCE}
        datastore: workload_share_vcsmdcncworkload2_vyC6a
    - name: us-east-3
      region:
        name: us-east
        type: Datacenter
        tagCategory: openshift-region
      zone:
        name: us-east-3a
        type: ComputeCluster
        tagCategory: openshift-zone
      topology:
        datacenter: "${vsphere_datacenter}"
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-3
        networks:
        - ${LEASED_RESOURCE}
        datastore: workload_share_vcsmdcncworkload3_joYiR
    - name: us-west-1
      region:
        name: us-west
        type: Datacenter
        tagCategory: openshift-region
      zone:
        name: us-west-1a
        type: ComputeCluster
        tagCategory: openshift-zone
      topology:
        datacenter: datacenter-2
        computeCluster: /datacenter-2/host/vcs-mdcnc-workload-4
        networks:
        - ${LEASED_RESOURCE}
        datastore: workload_share_vcsmdcncworkload3_joYiR

networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

curl -o ${SHARED_DIR}/manifest_externalFeatureGate.yaml https://raw.githubusercontent.com/openshift/cluster-cloud-controller-manager-operator/master/hack/externalFeatureGate.yaml


ZONAL_SC="${SHARED_DIR}/manifest_zonal-sc.yaml"
PROM_CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"


cat >> ${ZONAL_SC} << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-zone-us-east-1a
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - us-east-1a
parameters:
  diskformat: thin
provisioner: kubernetes.io/vsphere-volume
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

cat >> ${PROM_CONFIG} << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml:
    prometheusK8s:
      volumeClaimTemplate:
        spec:
          storageClassName: sc-zone-us-east-1a
EOF

