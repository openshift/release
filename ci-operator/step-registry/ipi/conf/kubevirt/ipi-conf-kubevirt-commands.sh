#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

KUBEVIRT_BASE_DOMAIN="ci.ocpcnv.ovirt.org"
KUBEVIRT_API_VIP=10.123.124.10
KUBEVIRT_INGRESS_VIP=10.123.124.11
KUBEVIRT_CIDR="10.123.124.0/24"
CLUSTER_NETWORK_CIDR="10.128.0.0/14"
SERVICE_NETWROK_CIDR="172.30.0.0/16"
KUBEVIRT_NAMESPACE=ipi-ci
KUBEVIRT_TENANT_CLUSTER_NAME=t1
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
  networkType: OpenShiftSDN
  serviceNetwork:
  - ${SERVICE_NETWROK_CIDR}
platform:
  kubevirt:
    # TODO this section is WIP - see the installer PR
    ingressVIP: ${KUBEVIRT_INGRESS_VIP}
    apiVIP: ${KUBEVIRT_API_VIP}
    namespace: ${KUBEVIRT_NAMESPACE}
    networkName: ${KUBEVIRT_NETWORK_NAME}
    persistentVolumeAccessMode: ${KUBEVIRT_VOLUME_ACCESS_MODE}
EOF