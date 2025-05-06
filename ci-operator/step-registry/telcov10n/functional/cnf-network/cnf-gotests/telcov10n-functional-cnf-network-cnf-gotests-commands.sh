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
cp ${SHARED_DIR}/switch ${ECO_CI_CD_INVENTORY_PATH}/host_vars/switch

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

echo Load INTERFACE_LIST,SWITCH_INTERFACES,VLAN env variablies
if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
    source ${SHARED_DIR}/set_ocp_net_vars.sh
fi

echo "Selected SRIOV interfaces"
echo INTERFACE_LIST=$INTERFACE_LIST

echo "Selected VLAN"
echo VLAN=$VLAN

echo "Selected SWITCH_INTERFACES"
echo SWITCH_INTERFACES=$SWITCH_INTERFACES

echo "Setup test script"
cd /eco-ci-cd
ansible-playbook ./playbooks/cnf/deploy-run-downstream-tests-script.yaml \
    -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig \
    cnf_interfaces=$INTERFACE_LIST \
    switch_interfaces=$SWITCH_INTERFACES \
    metallb_vlans=$VLAN \
    downstream_test_report_path=/tmp/downstream_report"

echo "Set bastion ssh configuration"
cat $SHARED_DIR/all | grep ansible_ssh_private_key -A 100 | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > $PROJECT_DIR/temp_ssh_key
chmod 600 $PROJECT_DIR/temp_ssh_key
BASTION_IP=$(cat $ECO_CI_CD_INVENTORY_PATH/host_vars/bastion | grep -oP '(?<=ansible_host: ).*' | sed "s/'//g")
BASTION_USER=$(cat $ECO_CI_CD_INVENTORY_PATH/group_vars/all | grep -oP '(?<=ansible_user: ).*'| sed "s/'//g")

echo "Run cnf-gotests via ssh tunnel"
ssh -o StrictHostKeyChecking=no $BASTION_USER@$BASTION_IP -i /tmp/temp_ssh_key "cd /tmp/cnf-gotests;./downstream-tests-run.sh || true"

echo "Gather artifacts from bastion"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key $BASTION_USER@$BASTION_IP:/tmp/downstream_report/*.xml ${ARTIFACT_DIR}/junit_downstream/
rm -rf $PROJECT_DIR/temp_ssh_key

echo "Store polarion report for reporter step"
mv ${ARTIFACT_DIR}/junit_downstream/report_polarion.xml ${SHARED_DIR}/report_polarion.xml
