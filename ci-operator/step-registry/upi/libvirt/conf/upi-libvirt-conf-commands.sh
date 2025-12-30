#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Installing from initial release ${RELEASE_IMAGE_LATEST}"

openshift-install version

CONFIG="${SHARED_DIR}/install-config.yaml"

CLUSTER_NAME="libvirt-s390x-amd64-0-0"
BASE_DOMAIN="ci"

cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_REPLICAS}
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  replicas: 0
networking:
  clusterNetwork:
  - cidr: 10.8.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
fips: false
EOF

yq-v4 eval ".pullSecret = load_str(\"${CLUSTER_PROFILE_DIR}/pull-secret\")" -i "${CONFIG}"
yq-v4 eval ".sshKey = load_str(\"${CLUSTER_PROFILE_DIR}/ssh-publickey\")" -i "${CONFIG}"