#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
PROJECT_DIR="/tmp"

echo "Create group_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Copy group inventory files"
# shellcheck disable=SC2154
cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Copy host inventory files"
cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/switch" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/switch"

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo Load INTERFACE_LIST,SWITCH_INTERFACES,VLAN env variablies
if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/set_ocp_net_vars.sh"
fi

if [[ -n "${INTERFACE_LIST}" ]]; then
  echo "Sriov INTERFACE_LIST env var is not empty append parameters to ECO_GOTESTS_ENV_VARS"
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_SRIOV_INTERFACE_LIST=${INTERFACE_LIST} ${ECO_GOTESTS_ENV_VARS}"
fi

if [[ -n "${VLAN}" ]]; then
  echo "VLAN env var is not empty append parameters to ECO_GOTESTS_ENV_VARS"
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_VLAN=${VLAN} ${ECO_GOTESTS_ENV_VARS}"
fi

if [[ -n "${SWITCH_INTERFACES}" ]]; then
  echo "SWITCH_INTERFACES env var is not empty append parameters to ECO_GOTESTS_ENV_VARS"
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_SWITCH_INTERFACES=${SWITCH_INTERFACES} ${ECO_GOTESTS_ENV_VARS}"
fi

echo "Show eco-gotests environment variables"
echo "${ECO_GOTESTS_ENV_VARS}"

echo "Setup test script"
cd /eco-ci-cd

# shellcheck disable=SC2154
ansible-playbook ./playbooks/cnf/deploy-run-eco-gotests.yaml -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "features=${FEATURES} labels=${LABELS} \
    kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig additional_test_env_variables='${ECO_GOTESTS_ENV_VARS}'"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"


chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run eco-gotests via ssh tunnel"
ssh -o StrictHostKeyChecking=no "${BASTION_USER}@${BASTION_IP}" -i /tmp/temp_ssh_key "cd /tmp/eco_gotests;./eco-gotests-run.sh || true"

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/eco_gotests/report/*.xml "${ARTIFACT_DIR}/junit_eco_gotests/"
rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Store polarion report for reporter step"
mv "${ARTIFACT_DIR}/junit_eco_gotests/report_testrun.xml" "${SHARED_DIR}/report_testrun.xml"
