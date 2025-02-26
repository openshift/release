#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ NROP Deployment setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

date +%s > "${SHARED_DIR}"/start_time

# Environment variables required
SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
T5CI_HCP_MGMT_KUBECONFIG="${T5CI_HCP_MGMT_KUBECONFIG:=${SHARED_DIR}/mgmt-kubeconfig}"
T5CI_HCP_HOSTED_KUBECONFIG="${T5CI_HCP_HOSTED_KUBECONFIG:=${SHARED_DIR}/kubeconfig}"
source "${SHARED_DIR}"/main.env

# Check if Inventory file exists
if ! [[ -f "${SHARED_DIR}"/inventory ]]; then
    echo "No inventory file found"
    exit 1;
fi

# Copy automation repo to local SHARED_DIR
echo "Copy automation repo to local $SHARED_DIR"
mkdir "${SHARED_DIR}"/repos
ssh -i "${SSH_PKEY}" "${COMMON_SSH_ARGS}" "${BASTION_USER}"@"${BASTION_IP}" \
    "tar --exclude='.git' -czf - -C /home/${BASTION_USER} ansible-automation" | tar -xzf - -C "${SHARED_DIR}"/repos/

# Install ansible dependencies
cd "${SHARED_DIR}"/repos/ansible-automation
pip3 install dnspython netaddr
ansible-galaxy collection install -r ansible-requirements.yaml

# Change the host to hypervisor
echo "Change the host from localhost to hypervisor"
sed -i "s/- hosts: localhost/- hosts: hypervisor/g" playbooks/apply_registry_certs.yml
sed -i "s/- hosts: localhost/- hosts: hypervisor/g" playbooks/install_nrop.yml

# Install certificates required for internal registries
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/ansible-automation/ansible.cfg
ansible-playbook -i "${SHARED_DIR}"/inventory -vv "${SHARED_DIR}"/repos/ansible-automation/playbooks/apply_registry_certs.yml \
-e kubeconfig="${T5CI_HCP_MGMT_KUBECONFIG}"

# Install NUMAResources Operator Playbook
ansible-playbook -i "${SHARED_DIR}"/inventory -vv "${SHARED_DIR}"/repos/ansible-automation/playbooks/install_nrop.yml \
-e hosted_kubeconfig="${T5CI_HCP_HOSTED_KUBECONFIG}" \
-e mgmt_kubeconfig="${T5CI_HCP_MGMT_KUBECONFIG}" \
-e install_sources="${T5CI_NROP_SOURCE}"

# Install telco-ci ansible modules
ansible-galaxy collection install -r "${SHARED_DIR}"/repos/telco-ci/ansible-requirements.yaml

# Applying performance profile suitable for NROP
echo "************ Applying Performance Profile suitable for NROP ************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/performance_profile_nrop.yml -e kubeconfig="${T5CI_HCP_MGMT_KUBECONFIG}" -c local
