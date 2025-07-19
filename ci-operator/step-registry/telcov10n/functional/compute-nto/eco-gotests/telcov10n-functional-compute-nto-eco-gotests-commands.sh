#!/bin/bash
set -e
set -o pipefail
set -x

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

echo "Set compute-nto specific environment variables"
ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_COMPUTE_NTO_ENABLED=true ${ECO_GOTESTS_ENV_VARS}"

# shellcheck disable=SC2154
if [[ "${ECO_GOTEST_BMC_ACCESS}" = "true" ]]; then
  ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_USER=$(grep -oP "(?<=bmc_user: ).*" "${SHARED_DIR}/all" | sed "s/'//g")"
  ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_PASS=$(grep -oP "(?<=bmc_password: ).*" "${SHARED_DIR}/all" | sed "s/'//g")"

  # Handle BMC address extraction from all worker files
  BMC_ADDRESSES=""
  for worker_file in "${SHARED_DIR}"/worker*; do
    if [[ -f "${worker_file}" ]]; then
      worker_name=$(basename "${worker_file}")
      BMC_ADDRESS=$(grep -oP "(?<=bmc_address: ).*" "${worker_file}" | sed "s/'//g" || echo "")
      if [[ -n "${BMC_ADDRESS}" ]]; then
        if [[ -n "${BMC_ADDRESSES}" ]]; then
          BMC_ADDRESSES="${BMC_ADDRESSES},${BMC_ADDRESS}"
        else
          BMC_ADDRESSES="${BMC_ADDRESS}"
        fi
        echo "BMC address found in ${worker_name}: ${BMC_ADDRESS}"
      else
        echo "Warning: bmc_address not found in ${worker_name}"
      fi
    fi
  done

  if [[ -n "${BMC_ADDRESSES}" ]]; then
    ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_NAMES=${BMC_ADDRESSES}"
    echo "All BMC addresses: ${BMC_ADDRESSES}"
  else
    echo "Warning: No BMC addresses found in any worker files"
    ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_NAMES="
  fi
fi

echo "Show compute-nto eco-gotests environment variables"
echo "${ECO_GOTESTS_ENV_VARS}"

echo "Setup compute-nto test script"
cd /eco-ci-cd

# shellcheck disable=SC2154
ansible-playbook ./playbooks/compute/deploy-nto-gotest.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "cluster_name=${CLUSTER_NAME} \
    kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Run NTO gotests via SSH (playbook creates files on bastion, not locally)"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run compute-nto eco-gotests via ssh tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no "${BASTION_USER}@${BASTION_IP}" -i /tmp/temp_ssh_key "cd /tmp/gotest && ./run_gotests.sh || true"

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests/"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/artifacts/*.xml "${ARTIFACT_DIR}/junit_eco_gotests/" || echo "No XML reports found on bastion"
rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Copy test reports to shared directory for reporter step"
cp -v "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml "${SHARED_DIR}/" 2>/dev/null || echo "No test reports found to copy to SHARED_DIR"
