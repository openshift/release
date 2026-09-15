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
MOUNTED_SPOKE_INVENTORY="/var/clusters/${CLUSTER_NAME}/spoke-master0"

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
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/all" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/hypervisors" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/hypervisors"
cp "${SHARED_DIR}/nodes" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/masters" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/bastion" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/hypervisor" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/hypervisor"

# Set up cnf inventory (used by deploy-run-eco-gotests.yaml / ibu-run-seedgeneration.yml)
mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/bastions" "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/all" "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/bastion" "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

echo "Installing spoke SNO inventory for master-0"
cp "${MOUNTED_SPOKE_INVENTORY}" "${CNF_INVENTORY_PATH}/host_vars/master-0.yaml"
cp "${MOUNTED_SPOKE_INVENTORY}" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master-0"


echo "Inventory copied from SHARED_DIR and spoke inventory processed"

echo ""
echo "=== Step 1: Prepare IBU seed SNO and retrieve kubeconfig ==="

cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}"

echo ""
echo "=== Step 2: Generate eco-gotests IBU seedgeneration script ==="
SEED_SPOKE_KUBECONFIG="/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig"

# Build eco-gotests environment variables
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

# Generate eco-gotests run script on bastion (does not execute)
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
echo "=== Step 2b: Run seedgeneration with pull-secret backup/restore ==="
# Backs up pull-secret, runs generated script, always restores + MCP wait,
# then verifies SeedGenerator/seedimage has SeedGenCompleted=True.

ansible-playbook playbooks/ran/ibu-run-seedgeneration.yml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}" \

echo "Set bastion SSH configuration"
PROJECT_DIR="/tmp"
# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "${PROJECT_DIR}/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${CNF_INVENTORY_PATH}/group_vars/all.yaml" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=^ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")

echo "Gather artifacts from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
  "${ARTIFACT_DIR}/junit_eco_gotests/" || true
rm -f "${PROJECT_DIR}/temp_ssh_key"

# ibu-report sends polarion_* files to Report Portal (POLARION_REPORT_PATH)
# and junit_* files to the Polarion converter (JUNIT_REPORT_PATH).
echo "Store Polarion and junit reports for reporter step"
for f in "${ARTIFACT_DIR}/junit_eco_gotests/"report_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying polarion report: ${filename} -> polarion_ibu_seed_${filename}"
    cp "$f" "${SHARED_DIR}/polarion_ibu_seed_${filename}"
  fi
done
for f in "${ARTIFACT_DIR}/junit_eco_gotests/"*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying junit report: ${filename} -> junit_ibu_seed_${filename}"
    cp "$f" "${SHARED_DIR}/junit_ibu_seed_${filename}"
  fi
done

echo ""
echo "=== Step 3: Power off seed spoke node ==="

# The private key spans several lines in the master-0 host vars, take everything between the quotes
install -m 600 /dev/null /tmp/spoke-master-ssh-key
sed -n "/^ansible_ssh_private_key: /,/'\$/p" \
  "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master-0" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" \
  > /tmp/spoke-master-ssh-key
ansible-playbook playbooks/ran/ibu-poweroff-seed-spoke.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --private-key=/tmp/spoke-master-ssh-key
rm -f /tmp/spoke-master-ssh-key

echo ""
echo "=== IBU Seed Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
echo "Seed spoke has been powered off and is ready for IBU upgrade"

