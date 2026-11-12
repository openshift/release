#!/bin/bash
set +x
set -euo pipefail
umask 077

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

# Prepare the seed while it is still managed by ACM and record its completed
# OpenShift version on the controller for subsequent IBI steps.
cd /eco-ci-cd
rm -f -- "${SHARED_DIR}/ibi-seed-version"
ansible-playbook playbooks/ran/ibi-seed-prepare.yml \
  -i "${INVENTORY_PATH}/build-inventory.py" \
  --limit bastion \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "ibi_seed_version_file=${SHARED_DIR}/ibi-seed-version" \
  --extra-vars "ibi_seed_diagnostics_dir=${ARTIFACT_DIR}"

# Ansible can exit successfully when the inventory matches no hosts.
test -s "${SHARED_DIR}/ibi-seed-version"
