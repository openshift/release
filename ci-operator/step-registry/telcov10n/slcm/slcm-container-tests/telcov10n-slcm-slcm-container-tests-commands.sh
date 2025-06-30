#!/bin/bash
# shellcheck disable=SC2153
# ARTIFACT_DIR is provided by the CI environment (Prow/OpenShift CI)

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
COPY_TO_PROW="$(cat /var/run/project-02/slcm-container/COPY_TO_PROW)"

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

## COPY JUNIT FILES FUNCTION
copy_junit_files() {
    
    ansible-playbook -i slcm_inventory.yml playbooks/run_slcm_container.yml -e @slcm_vars.yml --tags setup_vpn --skip-tags kill_vpn | tee ${ARTIFACT_DIR}/ansible_setup_vpn.log

    local REMOTE_JUNIT_DIR="/tmp/prow_pipeline_${BUILD_ID}"
    local JUMP_TEMP_DIR="/tmp/prow_junit_${BUILD_ID}"
    local success=0
    
    echo "=== Two-Step File Copy Process ==="
    
    # Test basic connectivity first
    echo "Testing connectivity to jump server..."
    if ! ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" "echo 'Jump server reachable'"; then
        echo "ERROR: Cannot reach jump server"
        return 1
    fi
    
    echo "Testing connectivity from jump server to target..."
    if ! ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
        "ssh -i ${SSH_KEY} ${SSHOPTS[*]} -o ConnectTimeout=10 ${REMOTE_USER}@${TB2SLCM1} 'echo Connection successful'"; then
        echo "ERROR: Cannot reach target server from jump server"
        return 1
    fi
    
    # Create temporary directory on jump server
    echo "Creating temporary directory on jump server..."
    ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
        "mkdir -p ${JUMP_TEMP_DIR}"
    
    # Step 1: Target -> Jump Server
    echo "=== Step 1: Target Server -> Jump Server ==="
    
    # Check and list files on target server
    echo "Checking for XML files on target server..."
    target_files=$(ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
        "ssh -i ${SSH_KEY} ${SSHOPTS[*]} ${REMOTE_USER}@${TB2SLCM1} 'ls -la ${REMOTE_JUNIT_DIR}/*.xml 2>/dev/null'" || echo "")
    
    file_count=$(echo "$target_files" | grep -c "\.xml$" || echo "0")
    
    if [[ "$file_count" -gt 0 ]]; then
        echo "Found $file_count XML files on target server:"
        echo "$target_files"
        ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
            "scp -i ${SSH_KEY} ${SSHOPTS[*]} ${REMOTE_USER}@${TB2SLCM1}:${REMOTE_JUNIT_DIR}/*.xml ${JUMP_TEMP_DIR}/"
        
        # Verify copy to jump server and list files
        jump_files=$(ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
            "ls -la ${JUMP_TEMP_DIR}/*.xml 2>/dev/null" || echo "")
        
        jump_file_count=$(echo "$jump_files" | grep -c "\.xml$" || echo "0")
        
        if [[ "$jump_file_count" -gt 0 ]]; then
            echo "Successfully copied $jump_file_count files to jump server:"
            echo "$jump_files"
            success=1
        else
            echo "WARNING: No files found on jump server after copy"
        fi
    else
        echo "No XML files found on target server"
    fi
    
    # Step 2: Jump Server -> Prow Server (only if files exist)
    if [[ $success -eq 1 ]]; then
        echo "=== Step 2: Jump Server -> Prow Server ==="
        
        scp -i "${SSH_KEY}" "${SSHOPTS[@]}" \
            "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}:${JUMP_TEMP_DIR}/*.xml" \
            "${ARTIFACT_DIR}/"
        
        # Verify final copy
        local_file_count=$(ls -1 "${ARTIFACT_DIR}"/*.xml 2>/dev/null | wc -l || echo "0")
        if [[ "$local_file_count" -gt 0 ]]; then
            echo "Successfully copied $local_file_count files to prow server"
            echo "Files in artifact directory:"
            ls -la "${ARTIFACT_DIR}"/*.xml
            
            # Cleanup remote directory on target server after successful copy
            echo "=== Cleanup: Removing remote directory on target server ==="
            ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
                "ssh -i ${SSH_KEY} ${SSHOPTS[*]} ${REMOTE_USER}@${TB2SLCM1} 'rm -rf ${REMOTE_JUNIT_DIR}'" && \
                echo "Successfully removed ${REMOTE_JUNIT_DIR} from target server" || \
                echo "WARNING: Could not remove ${REMOTE_JUNIT_DIR} from target server"
        else
            echo "WARNING: No files found in artifacts directory after copy"
            echo "Keeping remote directory ${REMOTE_JUNIT_DIR} on target server due to copy failure"
        fi
    fi
    
    # Cleanup
    echo "Cleaning up temporary directory on jump server..."
    ssh -i "${SSH_KEY}" "${SSHOPTS[@]}" "${JUMP_SERVER_USER}@${JUMP_SERVER_ADDRESS}" \
        "rm -rf ${JUMP_TEMP_DIR}" || echo "Cleanup warning: Could not remove temp directory"

    ansible-playbook -i slcm_inventory.yml playbooks/run_slcm_container.yml -e @slcm_vars.yml --tags kill_vpn | tee ${ARTIFACT_DIR}/ansible_kill_vpn.log
}

## CHECK TEST RESULTS FILES FUNCTION
check_test_failures() {
  shopt -s globstar nullglob
  local artifact_dir="${ARTIFACT_DIR:-.}"
  local failed=0
  local found_files=0

  for file in "${artifact_dir}"/**/*.xml; do
    found_files=1
    if grep -q '<testsuite[^>]*failures="[^0"]' "$file"; then
      echo "Test failure found in: $file"
      failed=1
    elif grep -q '<failure' "$file"; then
      echo "Failure element found in: $file"
      failed=1
    fi
  done

  if [[ $found_files -eq 0 ]]; then
    echo "No test result XML files found in ${artifact_dir}"
    return 1
  fi

  return $failed
}

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
COPY_TO_PROW: "${COPY_TO_PROW}"
PROW_JUNIT_TEMP_DIR: "/tmp/prow_pipeline_${BUILD_ID}"
infra_hosts:
  tb1slcm1: "${TB1SLCM1}"
  tb2slcm1: "${TB2SLCM1}"
END_VARS

ansible-galaxy collection install ansible.posix

set +e
ansible-playbook -i slcm_inventory.yml playbooks/run_slcm_container.yml -e @slcm_vars.yml | tee ${ARTIFACT_DIR}/ansible_slcm_inventory.log
ANSIBLE_EXIT_CODE=$?
set -e

if [[ $ANSIBLE_EXIT_CODE -ne 0 ]]; then
    echo "SLCM playbook failed with exit code $ANSIBLE_EXIT_CODE, but continuing to evaluate test results..."
fi

copy_junit_files
check_test_failures

if ! check_test_failures; then
  echo "Failed: either test failures detected or no test results found!"
  exit 1
else
  echo "All tests passed!"
fi