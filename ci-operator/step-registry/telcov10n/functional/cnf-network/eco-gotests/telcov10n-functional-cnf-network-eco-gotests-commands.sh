#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
PROJECT_DIR="/tmp"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

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

echo Load INTERFACE_LIST,SWITCH_INTERFACES,VLAN,NATIVE_VLAN env variables
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
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_VLAN=${VLAN%%,*} ${ECO_GOTESTS_ENV_VARS}"
fi

if [[ -n "${NATIVE_VLAN}" ]]; then
  echo "NATIVE_VLAN env var is not empty append parameters to ECO_GOTESTS_ENV_VARS"
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_NATIVE_VLAN=${NATIVE_VLAN} ${ECO_GOTESTS_ENV_VARS}"
fi

if [[ -n "${SWITCH_INTERFACES}" ]]; then
  echo "SWITCH_INTERFACES env var is not empty append parameters to ECO_GOTESTS_ENV_VARS"
  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_CORE_NET_SWITCH_INTERFACES=${SWITCH_INTERFACES} ${ECO_GOTESTS_ENV_VARS}"
fi

# shellcheck disable=SC2154
if [[ "${ECO_GOTEST_BMC_ACCESS}" = "true" ]]; then
  ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_USER=$(grep -oP "(?<=bmc_user: ).*" "${SHARED_DIR}/all" | sed "s/'//g")"
  ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_PASS=$(grep -oP "(?<=bmc_password: ).*" "${SHARED_DIR}/all" | sed "s/'//g")"
  ECO_GOTESTS_ENV_VARS+=" -e ECO_CNF_CORE_NET_BMC_HOST_NAMES=$(grep -oP "(?<=bmc_address: ).*" "${SHARED_DIR}/worker0" | sed "s/'//g")"
fi

echo "Show eco-gotests environment variables"
echo "${ECO_GOTESTS_ENV_VARS}"

echo "Setup test script"
cd /eco-ci-cd

# shellcheck disable=SC2154
ansible-playbook ./playbooks/deploy-run-eco-gotests.yaml -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "features=${FEATURES} labels=${LABELS} \
    kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig additional_test_env_variables='${ECO_GOTESTS_ENV_VARS}'"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"


chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run eco-gotests via ssh tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" -i /tmp/temp_ssh_key "cd /tmp/eco_gotests;./eco-gotests-run.sh || true"

echo "Gather artifacts from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests"
# shellcheck disable=SC2154
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/eco_gotests/report/*.xml "${ARTIFACT_DIR}/junit_eco_gotests/"
rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Combine per-suite ginkgo JUnit into polarion_eco_gotests.xml for reporter step"
python3 - "${ARTIFACT_DIR}/junit_eco_gotests" "${SHARED_DIR}/polarion_eco_gotests.xml" << 'PYEOF'
import re, sys, xml.etree.ElementTree as ET, glob, os
src_dir, out_file = sys.argv[1], sys.argv[2]
def strip(s):
    s = re.sub(r'<system-err>.*?</system-err>', '', s, flags=re.DOTALL)
    return re.sub(r'<system-out>.*?</system-out>', '', s, flags=re.DOTALL)
root = ET.Element('testsuite', {'name': 'eco-gotests'})
for f in sorted(glob.glob(os.path.join(src_dir, '*_junit.xml'))):
    try:
        tree = ET.fromstring(strip(open(f).read()))
        for suite in ([tree] if tree.tag == 'testsuite' else list(tree)):
            if suite.tag == 'testsuite':
                for tc in suite.findall('testcase'):
                    root.append(tc)
    except ET.ParseError:
        pass
ET.ElementTree(root).write(out_file, encoding='unicode', xml_declaration=True)
PYEOF
