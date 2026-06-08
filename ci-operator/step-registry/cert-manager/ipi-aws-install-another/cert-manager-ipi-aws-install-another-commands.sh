#!/bin/bash

set -euo pipefail

INSTALL_DIR=/tmp/installer-cluster2
mkdir -p "${INSTALL_DIR}"

if [[ -z "${RELEASE_IMAGE_LATEST}" ]]; then
  echo "RELEASE_IMAGE_LATEST is empty, exiting"
  exit 1
fi

echo "Installing second cluster from release ${RELEASE_IMAGE_LATEST}"

if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

REGION="${LEASED_RESOURCE}"

if [[ -n "${CLUSTER2_BASE_DOMAIN}" ]]; then
  BASE_DOMAIN="${CLUSTER2_BASE_DOMAIN}"
elif [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  BASE_DOMAIN=$(< "${CLUSTER_PROFILE_DIR}/baseDomain")
else
  BASE_DOMAIN="origin-ci-int-aws.dev.rhcloud.com"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}-2"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

cat > "${INSTALL_DIR}/install-config.yaml" << EOF
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
platform:
  aws:
    region: ${REGION}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: m6a.xlarge
  replicas: ${CLUSTER2_CONTROL_PLANE_REPLICAS}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: ${CLUSTER2_COMPUTE_NODE_TYPE}
  replicas: ${CLUSTER2_COMPUTE_NODE_REPLICAS}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

echo "Creating second cluster ${CLUSTER_NAME} in ${REGION}..."
openshift-install create cluster --dir="${INSTALL_DIR}" --log-level=info 2>&1 | tee "${ARTIFACT_DIR}/cluster2-install.log" &
wait "$!"

echo "Second cluster installed successfully"

cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-cluster2"
cp "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/metadata-cluster2.json"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password-cluster2"
