#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

## SLCM VARs
DCI_REMOTE_CI="$(cat /var/run/project-02/slcm-container/DCI_REMOTE_CI)"
CLOUD_RAN_PARTNER_REPO="$(cat /var/run/project-02/slcm-container/cloud_ran_partner_repo)"
CLOUD_RAN_PARTNER_REPO_VERSION="$(cat /var/run/project-02/slcm-container/cloud_ran_partner_repo_version)"
REMOTE_USER="$(cat /var/run/project-02/slcm-container/remote_user)"
CLUSTER_CONFIGS_DIR="$(cat /var/run/project-02/slcm-container/cluster_configs_dir)"
HUB_KUBECONFIG_PATH="$(cat /var/run/project-02/slcm-container/hub_kubeconfig_path)"
PODMAN_AUTH_PATH="$(cat /var/run/project-02/slcm-container/PODMAN_AUTH_PATH)"
VAULT_PASSWORD=$(cat /var/run/project-02/slcm-container/VAULT_PASSWORD)
ECO_GOTESTS_CONTAINER="$(cat /var/run/project-02/slcm-container/ECO_GOTESTS_CONTAINER)"
ECO_VALIDATION_CONTAINER="$(cat /var/run/project-02/slcm-container/ECO_VALIDATION_CONTAINER)"
TB1SLCM1="$(cat /var/run/project-02/slcm-container/tb1slcm1)"
TB2SLCM1="$(cat /var/run/project-02/slcm-container/tb2slcm1)"
SKIP_DCI="$(cat /var/run/project-02/slcm-container/SKIP_DCI)"
STAMP="$(cat /var/run/project-02/slcm-container/STAMP)"
LATENCY_DURATION="$(cat /var/run/project-02/slcm-container/LATENCY_DURATION)"
OCP_VERSION="$(cat /var/run/project-02/slcm-container/OCP_VERSION)"
SITE_NAME="$(cat /var/run/project-02/slcm-container/SITE_NAME)"
DCI_PIPELINE_FILES="$(cat /var/run/project-02/slcm-container/DCI_PIPELINE_FILES)"
EDU_PTP="$(cat /var/run/project-02/slcm-container/EDU_PTP)"

SLCM_VAULT=/var/run/project-02/vault-data/vault_data
cp $SLCM_VAULT playbooks/run_slcm_vault
chmod 0600 playbooks/run_slcm_vault

## VPN 
VPN_URL="$(cat /var/run/bastion1/vpn-url)"
VPN_USERNAME="$(cat /var/run/bastion1/vpn-username)"
VPN_PASSWORD=$(cat /var/run/bastion1/vpn-password)

## SSH 
SSH_KEY_PATH=/var/run/telcov10n/ansible_ssh_private_key
SSH_KEY=~/key
IFNAME=tun10

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

SSHOPTS=(
  -o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${SSH_KEY}"
)

## JUMP SERVER
JUMP_SERVER_ADDRESS="$(cat /var/run/bastion1/jump-server)"
JUMP_SERVER_USER="$(cat /var/run/telcov10n/ansible_user)"

## INVENTORY
cat << END_INVENTORY > slcm_inventory.yml
---
all:
  hosts:
    localhost:
      ansible_connection: local
  children:
    jumphost:
      hosts:
        jump_host:
          ansible_host: "${JUMP_SERVER_ADDRESS}"
          ansible_user: "${JUMP_SERVER_USER}"
          ansible_ssh_common_args: "${SSHOPTS[@]}"
          vpn_username: "${VPN_USERNAME}"
          vpn_password: "${VPN_PASSWORD}"
          vpn_url: "${VPN_URL}"
          tun_name: "${IFNAME}"
    targets:
      hosts:
        "${TB2SLCM1}":
          ansible_host: "${TB2SLCM1}"
          ansible_ssh_common_args: >-
            -i "${SSH_KEY}" ${SSHOPTS[*]}
            -o ProxyCommand="ssh -W %h:%p ${SSHOPTS[*]} -i "${SSH_KEY}" -q ${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}"
  vars:
    artifacts_dir: "${ARTIFACT_DIR}"
    remote_user: "${REMOTE_USER}"
END_INVENTORY

## VARs
cat << END_VARS > slcm_vars.yml
---
DCI_REMOTE_CI: "${DCI_REMOTE_CI}"
cloud_ran_partner_repo: "${CLOUD_RAN_PARTNER_REPO}"
cloud_ran_partner_repo_version: "${CLOUD_RAN_PARTNER_REPO_VERSION}"
remote_user: "${REMOTE_USER}"
cluster_configs_dir: "${CLUSTER_CONFIGS_DIR}"
hub_kubeconfig_path: "${HUB_KUBECONFIG_PATH}"
PODMAN_AUTH_PATH: "${PODMAN_AUTH_PATH}"
VAULT_PASSWORD: "${VAULT_PASSWORD}"
ECO_GOTESTS_CONTAINER: "${ECO_GOTESTS_CONTAINER}"
ECO_VALIDATION_CONTAINER: "${ECO_VALIDATION_CONTAINER}"
PROW_PIPELINE_ID: "${BUILD_ID}"
SKIP_DCI: "${SKIP_DCI}"
STAMP: "${STAMP}"
LATENCY_DURATION: "${LATENCY_DURATION}"
OCP_VERSION: "${OCP_VERSION}"
SITE_NAME: "${SITE_NAME}"
DCI_PIPELINE_FILES: "${DCI_PIPELINE_FILES}"
EDU_PTP: "${EDU_PTP}"
infra_hosts:
  tb1slcm1: "${TB1SLCM1}"
  tb2slcm1: "${TB2SLCM1}"
END_VARS

ansible-galaxy collection install ansible.posix
ansible-playbook -i slcm_inventory.yml playbooks/run_slcm_container.yml -e @slcm_vars.yml | tee  ${ARTIFACT_DIR}/ansible.log