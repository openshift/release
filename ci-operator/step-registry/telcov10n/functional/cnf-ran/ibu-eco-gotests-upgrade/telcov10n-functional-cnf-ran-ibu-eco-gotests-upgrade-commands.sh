#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi
        local content
        content=$(cat "$filename")
        local varname
        varname=$(basename "${filename}")
        # Check if content has newlines - if so, use literal block scalar (|)
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}: '${content//\'/\'\'}'"
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

OCP_DEPLOYMENT_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
CNF_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
MOUNTED_SPOKE_INVENTORY="/var/host_variables/${TARGET_CLUSTER_NAME}/spoke-master0"

echo "=== IBU Upgrade eco-gotests Configuration ==="
echo "TARGET_CLUSTER_NAME=${TARGET_CLUSTER_NAME}"
echo "TARGET_SPOKE_CLUSTER=${TARGET_SPOKE_CLUSTER}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
echo "VERSION=${VERSION}"
echo ""

# Copy target hub inventory from SHARED_DIR (target-* prefixed files saved by ibu-target-hub-deploy)
echo "=== Copying target hub inventory from SHARED_DIR ==="

mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/target-all"        "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/target-bastions"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/target-hypervisors" "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/hypervisors"
cp "${SHARED_DIR}/target-nodes"      "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/target-masters"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/target-bastion"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/target-hypervisor" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/hypervisor"
cp "${SHARED_DIR}/target-master0"    "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master0"

mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/target-bastions"   "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/target-all"        "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/target-bastion"    "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

echo "Processing target spoke SNO inventory with proper multi-line SSH key handling"
process_inventory "${MOUNTED_SPOKE_INVENTORY}" "${CNF_INVENTORY_PATH}/host_vars/master-0.yaml"
process_inventory "${MOUNTED_SPOKE_INVENTORY}" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master-0"

echo "Target hub inventory copied from SHARED_DIR and spoke inventory processed"

# Target hub kubeconfig at the standard telcov10n path on the target bastion
TARGET_HUB_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"
TARGET_VM_NAME="master-0.${TARGET_CLUSTER_NAME}"

echo ""
echo "=== Step 1: Prepare IBU target SNO and retrieve kubeconfig ==="

cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${TARGET_CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${TARGET_SPOKE_CLUSTER}" \
  --extra-vars "seed_vm_name=${TARGET_VM_NAME}"

echo ""
echo "=== Step 2: Run eco-gotests IBU upgrade suite ==="
TARGET_SPOKE_KUBECONFIG="/tmp/${TARGET_SPOKE_CLUSTER}-kubeconfig"

# Build eco-gotests environment variables
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=${TARGET_HUB_KUBECONFIG}"

ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "kubeconfig=${TARGET_SPOKE_KUBECONFIG}" \
  --extra-vars "features=${ECO_GOTESTS_FEATURES}" \
  --extra-vars 'labels=!no-container' \
  --extra-vars 'eco_worker_label=""' \
  --extra-vars 'eco_cnf_core_net_switch_user=""' \
  --extra-vars 'eco_cnf_core_net_switch_pass=""' \
  --extra-vars 'eco_gotests_tag=latest' \
  --extra-vars "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

echo "Set bastion SSH configuration"
PROJECT_DIR="/tmp"
grep ansible_ssh_private_key -A 100 "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")

echo "Run eco-gotests via SSH tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" \
  "cd /tmp/eco_gotests && ./eco-gotests-run.sh || true"

echo "Gather artifacts from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests_upgrade"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
  "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"
rm -f "${PROJECT_DIR}/temp_ssh_key"

# Save junit XMLs to SHARED_DIR with junit_ prefix for ibu-report step
for f in "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"*.xml; do
  [[ -f "$f" ]] && cp "$f" "${SHARED_DIR}/junit_ibu_upgrade_$(basename "$f")"
done

echo ""
echo "=== IBU Upgrade Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
