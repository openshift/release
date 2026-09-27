#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping seed preparation"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

# Load the seed inventory restored by ibu-restore-seed-inventory.
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
for key in all bastions nodes masters; do
  cp "${SHARED_DIR}/${key}" "${INVENTORY_PATH}/group_vars/${key}"
done
cp "${SHARED_DIR}/bastion" "${INVENTORY_PATH}/host_vars/bastion"

# Retrieve credentials while the seed is still managed by ACM. The playbook
# saves /tmp/${SEED_SPOKE_CLUSTER}-kubeconfig on the persistent seed bastion
# and prepares the CoreOS extensions image for seed generation.
cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}"
