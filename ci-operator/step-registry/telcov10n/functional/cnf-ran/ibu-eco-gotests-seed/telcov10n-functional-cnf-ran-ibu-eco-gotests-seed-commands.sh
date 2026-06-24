#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

OCP_DEPLOYMENT_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
CNF_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

echo "=== IBU Seed eco-gotests Configuration ==="
echo "SEED_SPOKE_CLUSTER=${SEED_SPOKE_CLUSTER}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
echo "VERSION=${VERSION}"
echo ""

# Copy inventory from SHARED_DIR (already processed by earlier hub-deploy step)
echo "=== Copying inventory for seed hub ${CLUSTER_NAME} from SHARED_DIR ==="

# Set up ocp-deployment inventory (used by prepare-ibu-seed-sno.yml and ibu-poweroff-seed-spoke.yml)
# Use seed- prefixed files explicitly to avoid ambiguity with target hub files in SHARED_DIR
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/seed-all" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/seed-bastions" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/seed-hypervisors" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/hypervisors"
cp "${SHARED_DIR}/seed-nodes" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/seed-masters" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/seed-bastion" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/seed-hypervisor" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/hypervisor"
cp "${SHARED_DIR}/seed-master0" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master0"

# Set up cnf inventory (used by deploy-run-eco-gotests.yaml)
mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/seed-masters" "${CNF_INVENTORY_PATH}/group_vars/masters.yaml"
cp "${SHARED_DIR}/seed-nodes" "${CNF_INVENTORY_PATH}/group_vars/nodes.yaml"
cp "${SHARED_DIR}/seed-hypervisors" "${CNF_INVENTORY_PATH}/group_vars/hypervisors.yaml"
cp "${SHARED_DIR}/seed-bastions" "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/seed-all" "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/seed-bastion" "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"
cp "${SHARED_DIR}/seed-master0" "${CNF_INVENTORY_PATH}/host_vars/master-0.yaml"
cp "${SHARED_DIR}/seed-hypervisor" "${CNF_INVENTORY_PATH}/host_vars/hypervisor.yaml"

echo "Inventory copied from SHARED_DIR"

echo ""
echo "=== Step 1: Prepare IBU seed SNO and retrieve kubeconfig ==="
SEED_VM_NAME="master-0.${CLUSTER_NAME}"

cd /eco-ci-cd
ansible-playbook playbooks/ran/prepare-ibu-seed-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "seed_vm_name=${SEED_VM_NAME}"

echo ""
echo "=== Step 2: Run eco-gotests IBU seedgeneration suite ==="
SEED_SPOKE_KUBECONFIG="/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig"

# Build eco-gotests environment variables
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

# Run eco-gotests
ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}" \
  --extra-vars "features=${ECO_GOTESTS_FEATURES}" \
  --extra-vars 'labels=!no-container' \
  --extra-vars 'eco_worker_label=""' \
  --extra-vars 'eco_cnf_core_net_switch_user=""' \
  --extra-vars 'eco_cnf_core_net_switch_pass=""' \
  --extra-vars 'eco_gotests_tag=latest' \
  --extra-vars "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

echo ""
echo "=== Step 3: Power off seed spoke VM ==="
ansible-playbook playbooks/ran/ibu-poweroff-seed-spoke.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py"

echo ""
echo "=== IBU Seed Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
echo "Seed spoke VM has been powered off and is ready for IBU upgrade"
