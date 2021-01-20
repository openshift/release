#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "Tenant cluster: ${LEASED_RESOURCE}"

HOME=/tmp
CONFIG="${SHARED_DIR}/install-config.yaml"

KUBEVIRT_BASE_DOMAIN="ci.ocpcnv.ovirt.org"
KUBEVIRT_API_VIP=$(<"${HOME}/secret-kube/${LEASED_RESOURCE}-api-vip")
KUBEVIRT_INGRESS_VIP=$(<"${HOME}/secret-kube/${LEASED_RESOURCE}-ingress-vip")
KUBEVIRT_CIDR="10.123.124.0/24"
CLUSTER_NETWORK_CIDR="10.128.0.0/14"
SERVICE_NETWORK_CIDR="172.30.0.0/16"
KUBEVIRT_NAMESPACE=ipi-ci
KUBEVIRT_TENANT_CLUSTER_NAME=$(<"${HOME}/secret-kube/${LEASED_RESOURCE}-cluster-name")
KUBEVIRT_NETWORK_NAME=mynet
KUBEVIRT_VOLUME_ACCESS_MODE=ReadWriteOnce

cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${KUBEVIRT_BASE_DOMAIN}
metadata:
  name: ${KUBEVIRT_TENANT_CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: 23
  machineNetwork:
  - cidr: ${KUBEVIRT_CIDR}
  networkType: ${NETWORK_TYPE}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
platform:
  kubevirt:
    # TODO this section is WIP - see the installer PR
    ingressVIP: ${KUBEVIRT_INGRESS_VIP}
    apiVIP: ${KUBEVIRT_API_VIP}
    namespace: ${KUBEVIRT_NAMESPACE}
    networkName: ${KUBEVIRT_NETWORK_NAME}
    persistentVolumeAccessMode: ${KUBEVIRT_VOLUME_ACCESS_MODE}
EOF