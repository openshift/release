#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Create basedomain.txt
echo "vmc-ci.devcluster.openshift.com" > "${SHARED_DIR}"/basedomain.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

master_replicas=${MASTER_REPLICAS:-"3"}
worker_replicas=${WORKER_REPLICAS:-"0"}

# Append platform type: none details
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: $master_replicas
compute:
- name: "worker"
  replicas: $worker_replicas
platform:
  none: {}
EOF
echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml
