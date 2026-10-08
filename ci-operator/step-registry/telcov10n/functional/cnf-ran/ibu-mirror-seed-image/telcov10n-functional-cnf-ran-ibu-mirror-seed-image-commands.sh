#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/seed-all"      /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/seed-bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp "${SHARED_DIR}/seed-bastion"  /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

echo "VERSION=${VERSION}"
echo "TARGET_REGISTRY_HOST=${TARGET_REGISTRY_HOST}"

cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-mirror-seed-image.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "version=${VERSION} target_registry_host=${TARGET_REGISTRY_HOST}"
