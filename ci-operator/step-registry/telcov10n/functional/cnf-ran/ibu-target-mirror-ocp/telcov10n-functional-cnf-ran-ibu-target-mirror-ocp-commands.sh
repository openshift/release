#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

echo "TARGET_SPOKE_VERSION=${TARGET_SPOKE_VERSION}"

cd /eco-ci-cd

echo "Mirroring OCP ${TARGET_SPOKE_VERSION} to target hub disconnected registry"
ansible-playbook ./playbooks/ran/mirror-ocp-release.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "release=${TARGET_SPOKE_VERSION}"
