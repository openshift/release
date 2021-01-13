#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1090
source ${SHARED_DIR}/ovirt-lease.conf
# shellcheck disable=SC1090
source ${CLUSTER_PROFILE_DIR}/ovirt.conf

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

cat >"${SHARED_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${OCP_CLUSTER}
compute:
- hyperthreading: Enabled
  name: worker
  platform:
    ovirt:
      cpu:
        cores: ${WORKER_CPU}
        sockets: 1
      memoryMB: ${WORKER_MEM}
      osDisk:
        # 31 is used to trigger the instance customization (the disk size is 16 Gi)
        sizeGB: 31
      vmType: server
      instanceTypeID:
  replicas: 2
controlPlane:
  hyperthreading: Enabled
  name: master
  platform:
    ovirt:
      cpu:
        cores: ${MASTER_CPU}
        sockets: 1
      memoryMB: ${MASTER_MEM}
      osDisk:
        # 31 is used to trigger the instance customization (the disk size is 16 Gi)
        sizeGB: 31
      vmType: server
      instanceTypeID:
  replicas: 3
platform:
  ovirt:
    ovirt_cluster_id: ${OVIRT_ENGINE_CLUSTER_ID}
    ovirt_storage_domain_id: ${OVIRT_ENGINE_STORAGE_DOMAIN_ID}
    api_vip: ${OVIRT_APIVIP}
    ingress_vip: ${OVIRT_INGRESSVIP}
    dns_vip: ${OVIRT_DNSVIP}
    ovirt_network_name: ${OVIRT_ENGINE_NETWORK}
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF