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

echo "=== IBI Seed eco-gotests Configuration ==="
echo "SEED_SPOKE_CLUSTER=${SEED_SPOKE_CLUSTER}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
echo "VERSION=${VERSION}"
echo "SEED_SPOKE_BMC_ADDRESS=${SEED_SPOKE_BMC_ADDRESS}"
echo ""

# Copy inventory from SHARED_DIR (processed by earlier hub-deploy step)
echo "=== Copying inventory for seed hub ${CLUSTER_NAME} from SHARED_DIR ==="

mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/all"       "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions"  "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/nodes"     "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/masters"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/bastion"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"

mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/bastions" "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/all"      "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/bastion"  "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

echo "Inventory copied from SHARED_DIR"

echo ""
echo "=== Step 1: Retrieve seed spoke kubeconfig from hub ACM ==="
cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${OCP_DEPLOYMENT_INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "skip_vm_disk_attachment=true"

echo ""
echo "=== Step 2: Generate eco-gotests IBI seedgeneration script ==="
SEED_SPOKE_KUBECONFIG="/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig"

ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

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
echo "=== Step 2b: Run seedgeneration ==="
ansible-playbook playbooks/ran/ibu-run-seedgeneration.yml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}"

echo "Set bastion SSH configuration"
PROJECT_DIR="/tmp"
grep ansible_ssh_private_key -A 100 "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | \
  sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")

echo "Gather artifacts from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
  "${ARTIFACT_DIR}/junit_eco_gotests/" || true
rm -f "${PROJECT_DIR}/temp_ssh_key"

for f in "${ARTIFACT_DIR}/junit_eco_gotests/"*.xml; do
  [[ -f "$f" ]] && cp "$f" "${SHARED_DIR}/junit_ibi_seed_$(basename "$f")"
done

echo ""
echo "=== Step 3: Power off seed spoke (helix81) via Redfish BMC ==="
BMC_USER="root"
BMC_PASS="calvin"

curl -6 -k -s -u "${BMC_USER}:${BMC_PASS}" -X POST \
  "${SEED_SPOKE_BMC_ADDRESS}/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset" \
  -H 'Content-Type: application/json' \
  -d '{"ResetType":"ForceOff"}' && echo "helix81 powered off via Redfish" || \
  echo "WARNING: Redfish power-off failed — manual power-off may be required"

echo ""
echo "=== IBI Seed Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
echo "Seed spoke (helix81) has been powered off and is ready for IBI"
