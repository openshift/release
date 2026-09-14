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
MOUNTED_SPOKE_INVENTORY="/var/clusters/${TARGET_CLUSTER_NAME}/spoke-master0"

echo "=== IBU Upgrade eco-gotests Configuration ==="
echo "TARGET_CLUSTER_NAME=${TARGET_CLUSTER_NAME}"
echo "TARGET_SPOKE_SNO=${TARGET_SPOKE_SNO}"
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

echo "Installing target spoke SNO inventory for master-0"
cp "${MOUNTED_SPOKE_INVENTORY}" "${CNF_INVENTORY_PATH}/host_vars/master-0.yaml"
cp "${MOUNTED_SPOKE_INVENTORY}" "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/master-0"

echo "Target hub inventory copied from SHARED_DIR and spoke inventory installed"

# Target hub kubeconfig at the standard telcov10n path on the target bastion
TARGET_HUB_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

echo ""
echo "=== Step 1: Prepare IBU target SNO and retrieve kubeconfig ==="

cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${TARGET_CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${TARGET_SPOKE_SNO}"

echo ""
echo "=== Step 2: Run eco-gotests IBU upgrade suite ==="
TARGET_SPOKE_KUBECONFIG="/tmp/${TARGET_SPOKE_SNO}-kubeconfig"

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
# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "${PROJECT_DIR}/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${CNF_INVENTORY_PATH}/group_vars/all.yaml" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=^ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")

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
  "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/" || echo "No XML artifacts in eco_gotests upgrade — skipping"
rm -f "${PROJECT_DIR}/temp_ssh_key"

# ibu-report sends polarion_* files to Report Portal (POLARION_REPORT_PATH)
# and junit_* files to the Polarion converter (JUNIT_REPORT_PATH).
echo "Store Polarion and junit reports for reporter step"
for f in "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"report_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying polarion report: ${filename} -> polarion_ibu_upgrade_${filename}"
    cp "$f" "${SHARED_DIR}/polarion_ibu_upgrade_${filename}"
  fi
done
for f in "${ARTIFACT_DIR}/junit_eco_gotests_upgrade/"*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying junit report: ${filename} -> junit_ibu_upgrade_${filename}"
    cp "$f" "${SHARED_DIR}/junit_ibu_upgrade_${filename}"
  fi
done

echo ""
echo "=== IBU Upgrade Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
