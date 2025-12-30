#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x
echo "************ NROP Deployment setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

date +%s > "${SHARED_DIR}"/start_time

# Environment variables required
export KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig
NODEPOOL_NAME=$(oc get np -n clusters -o json | jq -r '.items[0].metadata.name')
export CLUSTER_NAME="${NODEPOOL_NAME}"
export SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
T5CI_HCP_MGMT_KUBECONFIG="/home/kni/.kube/config_sno-${CLUSTER_NAME}"
T5CI_HCP_HOSTED_KUBECONFIG="/home/kni/.kube/hcp_config_${CLUSTER_NAME}"
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
source "${SHARED_DIR}"/main.env
echo "shared directory: ${SHARED_DIR}"

# Check if Inventory file exists
if ! [[ -f "${SHARED_DIR}"/inventory ]]; then
    echo "No inventory file found"
    exit 1;
fi

# check if mgmt-kubeconfig file exists
if ! [[ -f "${SHARED_DIR}/mgmt-kubeconfig" ]]; then
   echo "No Management cluster kubeconfig found"
   exit 1;
fi

# Check hosted cluster kubeconfig
if ! [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
   echo "No hosted cluster kubeconfig found"
   exit 1;
fi

# Check connectivity
ping ${BASTION_IP} -c 10 || true
echo "exit" | ncat "${BASTION_IP}" 22 && echo "SSH port is opened"|| echo "status = $?"

# Copy automation repo to local SHARED_DIR
echo "Copy automation repo to local $SHARED_DIR"
mkdir "${SHARED_DIR}"/repos

# git clone telco-ci
git clone "${TELCO_CI_REPO}" "${SHARED_DIR}"/repos/telco-ci

echo "shared directory: ${SHARED_DIR}"
ssh -i $SSH_PKEY $COMMON_SSH_ARGS ${BASTION_USER}@${BASTION_IP} \
    "tar --exclude='.git' -czf - -C /home/${BASTION_USER} ansible-automation" | tar -xzf - -C $SHARED_DIR/repos/

# Install ansible dependencies
cd "${SHARED_DIR}"/repos/ansible-automation
pip3 install dnspython netaddr
ansible-galaxy collection install -r ansible-requirements.yaml

# Change the host to hypervisor
echo "Change the host from localhost to hypervisor"
sed -i "s/- hosts: localhost/- hosts: hypervisor/g" playbooks/apply_registry_certs.yml
sed -i "s/- hosts: localhost/- hosts: hypervisor/g" playbooks/install_nrop.yml

echo "Managment kubeconfig file: ${T5CI_HCP_MGMT_KUBECONFIG}"
echo "Hosted cluster kubeconfig file: ${T5CI_HCP_HOSTED_KUBECONFIG}"

ansible_playbook_status=0

# Install certificates required for internal registries
# Not required due to konflux changes
# export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/ansible-automation/ansible.cfg
# ansible-playbook -i "${SHARED_DIR}"/inventory -vv "${SHARED_DIR}"/repos/ansible-automation/playbooks/apply_registry_certs.yml \
# -e kubeconfig="${T5CI_HCP_MGMT_KUBECONFIG}" || ansible_playbook_status=$?

echo "Status of Ansible playbook to install certificates required for internal registires is: ${ansible_playbook_status}"

# Install NUMAResources Operator Playbook
ansible-playbook -i "${SHARED_DIR}"/inventory -vv "${SHARED_DIR}"/repos/ansible-automation/playbooks/install_nrop.yml \
-e nrop_hosted_kubeconfig="${T5CI_HCP_HOSTED_KUBECONFIG}" \
-e nrop_mgmt_kubeconfig="${T5CI_HCP_MGMT_KUBECONFIG}" \
-e install_method="${T5CI_NROP_SOURCE}" || ansible_playbook_status=$?

echo "Status of Ansible playbook to deploy NROP operator is: ${ansible_playbook_status}"

# Applying performance profile suitable for NROP
echo "************ Applying Performance Profile suitable for NROP ************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/performance_profile_nrop.yml -e kubeconfig="${SHARED_DIR}/mgmt-kubeconfig" -c local || ansible_playbook_status=$?

echo "Status of Ansible playbook to deploy performance profile is: ${ansible_playbook_status}"

# Apply sample devices for NROP
echo "*********** Applying Sample devices *********************"
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/sample-devices.yml -e hosted_kubeconfig="${SHARED_DIR}/kubeconfig" -c local || ansible_playbook_status=$?

