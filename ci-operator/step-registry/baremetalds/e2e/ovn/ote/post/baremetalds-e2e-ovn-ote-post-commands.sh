#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e OVN OTE VM cleanup script ************"

# Validate required files exist
if [[ ! -f "${SHARED_DIR}/server-ip" ]]; then
    echo "WARNING: ${SHARED_DIR}/server-ip file not found, skipping cleanup"
    exit 0
fi

HYPERVISOR_IP=$(cat "${SHARED_DIR}/server-ip")

# Validate HYPERVISOR_IP is not empty
if [[ -z "${HYPERVISOR_IP}" ]]; then
    echo "WARNING: HYPERVISOR_IP is empty, skipping cleanup"
    exit 0
fi

# Determine SSH key location
if [[ -f "${CLUSTER_PROFILE_DIR}/equinix-ssh-key" ]]; then
    HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/equinix-ssh-key"
elif [[ -f "${CLUSTER_PROFILE_DIR}/packet-ssh-key" ]]; then
    HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
else
    echo "WARNING: SSH key not found in ${CLUSTER_PROFILE_DIR}, skipping cleanup"
    exit 0
fi

# Initialize arrays for podman configuration
PODMAN_MOUNTS=(-v "${HYPERVISOR_SSH_KEY}:/tmp/ssh-key")

# Prepare environment variables to pass to container as array
PODMAN_ENV=(-e "HYPERVISOR_IP=${HYPERVISOR_IP}" -e "HYPERVISOR_SSH_KEY=/tmp/ssh-key")

function cleanup_vm_from_nested_container() {
    # Prepare SSH and kcli configuration directories
    mkdir -p ~/.ssh ~/.kcli

    # Setup SSH key
    cp /tmp/ssh-key ~/.ssh/hypervisor-ssh-key
    chmod 600 ~/.ssh/hypervisor-ssh-key

    # Configure SSH client - use the copied key with correct permissions
    cat > ~/.ssh/config <<EOF
Host hypervisor
    HostName ${HYPERVISOR_IP}
    User root
    ServerAliveInterval 120
    IdentityFile ~/.ssh/hypervisor-ssh-key
EOF

    # Configure kcli
    cat > ~/.kcli/config.yml <<'EOF'
twix:
  host: hypervisor
  pool: default
  protocol: ssh
  type: kvm
  user: root
EOF

    # Delete the test VM
    echo "Deleting test VM 'ovn-kubernetes-e2e'"
    # Allow deletion to fail gracefully if VM doesn't exist
    if kcli delete vm ovn-kubernetes-e2e -y 2>&1; then
        echo "Successfully deleted VM 'ovn-kubernetes-e2e'"
    else
        local exit_code=$?
        echo "WARNING: Failed to delete VM or VM does not exist (exit code: ${exit_code})"
        # Don't fail the script if VM doesn't exist
        true
    fi

    echo "VM cleanup completed"
}

if [[ "${CREATE_HYPERVISOR_VM:-false}" == "true" ]]; then
    echo "Starting VM cleanup on remote hypervisor"
    # Execute cleanup in nested container
    # Allow cleanup to fail gracefully without failing the job
    if podman run --network host --rm -i \
        "${PODMAN_ENV[@]}" \
        "${PODMAN_MOUNTS[@]}" \
        --entrypoint /bin/bash \
        "quay.io/karmab/kcli" \
        -c "$(declare -f cleanup_vm_from_nested_container); cleanup_vm_from_nested_container"; then
        echo "VM cleanup completed successfully"
    else
        exit_code=$?
        echo "WARNING: VM cleanup encountered errors (exit code: ${exit_code}) but continuing"
        # Don't fail the post step even if cleanup has issues
        true
    fi
else
    echo "Skipping VM cleanup (CREATE_HYPERVISOR_VM not set to 'true')"
fi
