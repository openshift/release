#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset


CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN="$CLUSTER_NAME.oci-rhelcert.edge-sro.rhecoeng.com"

echo "Preparing agent-config.yaml"


cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: $CLUSTER_NAME
  namespace: cluster0
rendezvousIP: 10.0.0.2
EOF


ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

echo "Preparing install-config.yaml"


cat > "${SHARED_DIR}/install-config.yaml" <<EOF
apiVersion: v1
metadata:
  name: $CLUSTER_NAME
baseDomain: $BASE_DOMAIN
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/20
  serviceNetwork:
  - 172.30.0.0/16
compute:
- name: worker
  architecture: amd64
  hyperthreading: Enabled
  replicas: 0
  platform: {}
controlPlane:
  name: master
  replicas: 4
  architecture: amd64
  hyperthreading: Enabled
  platform: {}
platform:
    external:
      platformName: oci
      cloudControllerManager: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF