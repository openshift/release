#!/bin/bash
set +x
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

RELEASE_VARS="release=${TARGET_SPOKE_VERSION}"
INVENTORY_PREFIX=""
if [[ "${IBI_USE_SEED_RELEASE:-false}" == "true" ]]; then
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  SEED_RELEASE_IMAGE=$(<"${SHARED_DIR}/ibi-seed-release-image")
  [[ -n "${SEED_VERSION}" && "${SEED_RELEASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]]
  RELEASE_VARS="release=${SEED_RELEASE_IMAGE} release_version=${SEED_VERSION}"
  INVENTORY_PREFIX="target-"
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/${INVENTORY_PREFIX}all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/${INVENTORY_PREFIX}bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/${INVENTORY_PREFIX}bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "TARGET_SPOKE_VERSION=${TARGET_SPOKE_VERSION}"

cd /eco-ci-cd

echo "Mirroring OCP ${SEED_VERSION:-${TARGET_SPOKE_VERSION}} to target hub disconnected registry"
ansible-playbook ./playbooks/ran/ibu-prepare-ocp-release.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "${RELEASE_VARS}" \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH}"
