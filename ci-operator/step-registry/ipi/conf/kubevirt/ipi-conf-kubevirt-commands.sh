#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

KUBEVIRT_BASE_DOMAIN="testci.tenant1.dev.openshift.com"
KUBEVIRT_API_VIP=10.123.124.15
KUBEVIRT_INGRESS_VIP=10.123.124.20
KUBEVIRT_CIDR="10.123.124.0/24"
KUBEVIRT_NAMESPACE=tenantcluster
KUBEVIRT_NETWORK_NAME=mynet
KUBEVIRT_TENANT_STORAGE_CLASS_NAME=standard
KUBEVIRT_VOLUME_ACCESS_MODE=ReadWriteOnce

cat >> "${CONFIG}" << EOF
baseDomain: ${KUBEVIRT_BASE_DOMAIN}
metadata:
  name: ${KUBEVIRT_NAMESPACE}
networking:
  machineNetwork:
  - cidr: ${KUBEVIRT_CIDR}
compute:
  - name: worker
    replicas: ${COMPUTE_REPLICAS}
platform:
  kubevirt:
    # TODO this section is WIP - see the installer PR
    ingressVIP: ${KUBEVIRT_INGRESS_VIP}
    apiVIP: ${KUBEVIRT_API_VIP}
    namespace: ${KUBEVIRT_NAMESPACE}
    networkName: ${KUBEVIRT_NETWORK_NAME}
    storageClass: ${KUBEVIRT_TENANT_STORAGE_CLASS_NAME}
    persistentVolumeAccessMode: ${KUBEVIRT_VOLUME_ACCESS_MODE}
EOF
