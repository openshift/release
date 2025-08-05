#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
PROJECT_DIR="/tmp"

echo "Create group_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Copy group inventory files"
# shellcheck disable=SC2154
cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Copy host inventory files"
cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Load compute-nto specific environment variables"
if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/set_ocp_net_vars.sh"
fi

echo "Setup compute-nto test script"
cd /eco-ci-cd

# shellcheck disable=SC2154
set -x
ansible-playbook ./playbooks/compute/deploy-nto-gotest.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "cluster_name=${CLUSTER_NAME} \
    kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
set +x

echo "Run NTO gotests via SSH (playbook creates files on bastion, not locally)"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run compute-nto eco-gotests via ssh tunnel"
timeout -s 9 2h ssh \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no \
  "${BASTION_USER}@${BASTION_IP}" -i ${PROJECT_DIR}/temp_ssh_key bash -s -- << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

echo
echo "--------------------------------------------------"
echo "Running gotests script: /tmp/gotest/run_gotests.sh"
echo "--------------------------------------------------"
cat /tmp/gotest/run_gotests.sh
echo "--------------------------------------------------"
echo
cd /tmp/gotest && ./run_gotests.sh || true
EOF
set +x

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests/"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${PROJECT_DIR}/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/artifacts/*.xml "${ARTIFACT_DIR}/junit_eco_gotests/" || echo "No XML reports found on bastion"
rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Create junit-named copies in ARTIFACT_DIR for reporter compatibility"
for xml_file in "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml; do
  if [[ -f "${xml_file}" ]]; then
    basename_file=$(basename "${xml_file}")
    # Prepend junit_ to any XML filename
    junit_name="junit_${basename_file}"
    cp -v "${xml_file}" "${ARTIFACT_DIR}/junit_eco_gotests/${junit_name}"
    echo "Created junit copy: ${basename_file} -> ${junit_name}"
  fi
done

echo "Copy junit test reports to shared directory for reporter step"
cp -v "${ARTIFACT_DIR}"/junit_eco_gotests/junit_*.xml "${SHARED_DIR}/" 2>/dev/null || echo "No junit test reports found to copy to SHARED_DIR"
