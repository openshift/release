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
#ova_url=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')
#vm_template="${ova_url##*/}"

VERSION=$(echo "${JOB_NAME}" | grep -o -E '4\.[0-9]+')
if [ ! -z ${VERSION} ]; then
    Z_VERSION=$(echo ${VERSION} | cut -d'.' -f2)
    if [ ${Z_VERSION} -gt 13  ]; then
      if [ ${ENABLE_TEMPLATE} == "yes" ]; then
	      ova_url=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')
	      vm_template="${ova_url##*/}"
              #TEMPLATE_SETTING="template: /${vsphere_datacenter}/vm/${vm_template}"
	      #echo ${TEMPLATE_SETTING}
	      if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]; then
		      echo "Boot image ${vm_template} does not exist on ${vsphere_url}, uploading..."
	              cat <<EOF > /${SHARED_DIR}/upload_template.json
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${vm_template}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${LEASED_RESOURCE}"}]
}
EOF
                      echo "OVA URL: ${ova_url}"
                      curl -L -o /tmp/${vm_template} "${ova_url}"
                      govc import.ova -options=/${SHARED_DIR}/upload_template.json /${SHARED_DIR}/${vm_template} || ret=$?
		      TEMPLATE_SETTING="template: /${vsphere_datacenter}/vm/${vm_template}"
                  if [[ ret -ne 0 ]]; then
			  echo "Fail to upload ova image ${vm_template}!"
			  exit 1
                  fi
	      else 
		      TEMPLATE_SETTING="template: /${vsphere_datacenter}/vm/${vm_template}"
	      fi
      else
	      TEMPLATE_SETTING=""
      fi
    fi
fi

TECH_PREVIEW_NO_UPGRADE=""
if [[ "$JOB_NAME" == *"4.12-e2e-vsphere-zones"* ]]; then
  echo "$(date -u --rfc-3339=seconds) - setting tech preview feature gate for 4.12 zonal install"
  TECH_PREVIEW_NO_UPGRADE="featureSet: TechPreviewNoUpgrade"
fi

cat >> "${CONFIG}" << EOF
baseDomain: $base_domain
${TECH_PREVIEW_NO_UPGRADE}
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
    defaultDatastore: mdcnc-ds-shared
    failureDomains:
    - name: us-east-1
      region: us-east
      zone: us-east-1a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-1
        networks:
        - ${LEASED_RESOURCE}
        datastore: mdcnc-ds-1
        ${TEMPLATE_SETTING}
    - name: us-east-2
      region: us-east
      zone: us-east-2a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-2
        networks:
        - ${LEASED_RESOURCE}
        datastore: mdcnc-ds-2
        ${TEMPLATE_SETTING}
    - name: us-east-3
      region: us-east
      zone: us-east-3a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-3
        networks:
        - ${LEASED_RESOURCE}
        datastore: mdcnc-ds-3
        ${TEMPLATE_SETTING}
    - name: us-west-1
      region: us-west
      zone: us-west-1a
      topology:
        datacenter: datacenter-2
        computeCluster: /datacenter-2/host/vcs-mdcnc-workload-4
        networks:
        - ${LEASED_RESOURCE}
        datastore: mdcnc-ds-4
        ${TEMPLATE_SETTING}

networking:
  networkType: OpenShiftSDN
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

# TODO: Add this back in once we have an vsphere
# environment that will support topology storage

#ZONAL_SC="${SHARED_DIR}/manifest_zonal-sc.yaml"
#PROM_CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
#
#
#cat >> ${ZONAL_SC} << EOF
#apiVersion: storage.k8s.io/v1
#kind: StorageClass
#metadata:
#  name: sc-zone-us-east-1a
#allowedTopologies:
#- matchLabelExpressions:
#  - key: topology.kubernetes.io/zone
#    values:
#    - us-east-1a
#parameters:
#  diskformat: thin
#provisioner: kubernetes.io/vsphere-volume
#reclaimPolicy: Delete
#volumeBindingMode: WaitForFirstConsumer
#EOF
#
#cat >> ${PROM_CONFIG} << EOF
#apiVersion: v1
#kind: ConfigMap
#metadata:
#  name: cluster-monitoring-config
#  namespace: openshift-monitoring
#data:
#  config.yaml:
#    prometheusK8s:
#      volumeClaimTemplate:
#        spec:
#          storageClassName: sc-zone-us-east-1a
#EOF

