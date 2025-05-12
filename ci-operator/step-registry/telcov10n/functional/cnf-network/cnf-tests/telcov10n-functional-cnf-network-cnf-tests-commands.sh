#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
PROJECT_DIR="/tmp"

echo "Create group_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all ${ECO_CI_CD_INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/bastions ${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions

echo "Create host_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion ${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion


echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

echo Load INTERFACE_LIST env variable
if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
    source ${SHARED_DIR}/set_ocp_net_vars.sh
fi

echo "Selected SRIOV interfaces"
echo INTERFACE_LIST=$INTERFACE_LIST

echo "Selected FEATURES_TO_TEST"
echo FEATURES_TO_TEST=$FEATURES_TO_TEST

echo "Setup test script"
cd /eco-ci-cd
ansible-playbook ./playbooks/cnf/deploy-run-cnf-tests-script.yaml \
    -i ./inventories/cnf/run-tests.yaml \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig \
        cnf_interfaces=${INTERFACE_LIST} \
        features='$FEATURES_TO_TEST' \
        oo_install_ns=metallb-system \
        cnf_test_dir=$PROJECT_DIR/ \
        cnftests_git_dest=cnf-features-deploy"

echo "Set bastion ssh configuration"
cat $SHARED_DIR/all | grep ansible_ssh_private_key -A 100 | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > $PROJECT_DIR/temp_ssh_key
chmod 600 $PROJECT_DIR/temp_ssh_key
BASTION_IP=$(cat /eco-ci-cd/inventories/cnf/host_vars/bastion | grep -oP '(?<=ansible_host: ).*' | sed "s/'//g")
BASTION_USER=$(cat /eco-ci-cd/inventories/cnf/group_vars/all | grep -oP '(?<=ansible_user: ).*'| sed "s/'//g")

echo "Run cnf-tests via ssh tunnel"
ssh -o StrictHostKeyChecking=no $BASTION_USER@$BASTION_IP -i /tmp/temp_ssh_key "cd /tmp/cnf-features-deploy;./cnf-tests-run.sh || true"

echo "Gather artifacts from bastion"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key $BASTION_USER@$BASTION_IP:/tmp/junit/cnftests-junit.xml ${ARTIFACT_DIR}/junit_test-result.xml

echo "Store report for reporter step"
cp "${ARTIFACT_DIR}/junit_test-result.xml" "${SHARED_DIR}/junit_test-result.xml"

rm -rf $PROJECT_DIR/temp_ssh_key
