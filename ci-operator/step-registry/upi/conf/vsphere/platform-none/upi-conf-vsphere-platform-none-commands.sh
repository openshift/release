#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Create basedomain.txt
echo "vmc-ci.devcluster.openshift.com" > "${SHARED_DIR}"/basedomain.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

# Append platform type: none details
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
compute:
- name: "worker"
  replicas: 0
platform:
  none: {}
EOF
echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml
