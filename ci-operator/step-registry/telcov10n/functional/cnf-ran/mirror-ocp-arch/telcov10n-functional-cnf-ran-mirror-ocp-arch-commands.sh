#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp "${SHARED_DIR}/hypervisors" /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
cp "${SHARED_DIR}/nodes" /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
cp "${SHARED_DIR}/masters" /eco-ci-cd/inventories/ocp-deployment/group_vars/masters

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars
cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp "${SHARED_DIR}/hypervisor" /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
cp "${SHARED_DIR}/master0" /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

cd /eco-ci-cd

echo "Mirroring ${SPOKE_ARCH} architecture OCP release ${VERSION} to disconnected registry"
ansible-playbook ./playbooks/mirror-ocp.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "release=${VERSION} arch=${SPOKE_ARCH}"
