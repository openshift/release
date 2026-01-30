#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e OVN OTE VM setup script ************"

# Validate required files exist
if [[ ! -f "${SHARED_DIR}/server-ip" ]]; then
    echo "ERROR: ${SHARED_DIR}/server-ip file not found"
    exit 1
fi

HYPERVISOR_IP=$(cat "${SHARED_DIR}/server-ip")

# Determine SSH key location
if [[ -f "${CLUSTER_PROFILE_DIR}/equinix-ssh-key" ]]; then
    HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/equinix-ssh-key"
elif [[ -f "${CLUSTER_PROFILE_DIR}/packet-ssh-key" ]]; then
    HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
else
    echo "ERROR: SSH key not found in ${CLUSTER_PROFILE_DIR}"
    exit 1
fi

# Initialize arrays for podman configuration
PODMAN_MOUNTS=(-v "${HYPERVISOR_SSH_KEY}:/tmp/ssh-key:ro")
PODMAN_MOUNTS+=(-v "${SHARED_DIR}:/tmp/shared")

# Prepare environment variables to pass to container as array
PODMAN_ENV=(-e "HYPERVISOR_IP=${HYPERVISOR_IP}" -e "HYPERVISOR_SSH_KEY=/tmp/ssh-key")

function setup_vm_from_nested_container() {
    # Setup SSH options for remote hypervisor access
    SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o 'LogLevel=ERROR' -i "${HYPERVISOR_SSH_KEY}")

    # Prepare SSH and kcli configuration directories
    mkdir -p ~/.ssh ~/.kcli

    cp /tmp/ssh-key ~/.ssh/hypervisor-ssh-key
    chmod 600 ~/.ssh/hypervisor-ssh-key
    # Generate ssh keys which is needed for running kcli commands
    if [ ! -f ~/.ssh/id_ed25519 ]; then
      ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
    fi

    # Configure SSH client - use the copied key with correct permissions
    # The hypervisor VM is assigned an IP from the default network
    # (192.168.122.0/24), so wildcard SSH access is enabled for
    # the 192.168.122.* subnet.
    cat > ~/.ssh/config <<EOF
Host hypervisor
    HostName ${HYPERVISOR_IP}
    User root
    ServerAliveInterval 120
    IdentityFile ~/.ssh/hypervisor-ssh-key

Host 192.168.122.*
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyCommand ssh -W %h:%p hypervisor
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

    # Clean up any existing VM to ensure clean state
    echo "Ensuring clean state for VM creation"
    kcli delete vm ovn-kubernetes-e2e -y 2>/dev/null || true

    # Create test VM with Docker installed
    echo "Creating test VM with Docker"
    kcli create vm -i fedora42 ovn-kubernetes-e2e --wait -P "cmds=['dnf install -y docker','systemctl enable --now docker']"

    # Verify Docker installation
    echo "Verifying Docker installation in VM"
    if ! kcli ssh ovn-kubernetes-e2e -- sudo docker version; then
        echo "ERROR: Docker installation failed in VM"
        exit 1
    fi

    # Get VM IP address and save to shared directory
    echo "Retrieving VM IP address"
    VM_IP=$(kcli show vm ovn-kubernetes-e2e -o json | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ip",""))')

    if [[ -z "${VM_IP}" ]]; then
        echo "ERROR: Failed to retrieve VM IP address"
        exit 1
    fi

    echo "Copying VM IP ${VM_IP} to shared directory"
    echo "${VM_IP}" > /tmp/shared/vm-ip

    echo "Copying VM ssh keys to shared directory"
    cp ~/.ssh/id_ed25519 /tmp/shared/vm-private-key
    cp ~/.ssh/id_ed25519.pub /tmp/shared/vm-public-key

    # Attach primary network interface to VM
    echo "Detecting primary network interface on hypervisor"
    PRIMARY_NETWORK=$(ssh "${SSHOPTS[@]}" "root@${HYPERVISOR_IP}" ip -o link show | awk -F': ' '{print $2}' | grep 'bm$' | head -n1)

    if [[ -z "${PRIMARY_NETWORK}" ]]; then
        echo "ERROR: Failed to detect primary network interface on hypervisor"
        exit 1
    fi

    echo "Attaching primary network interface '${PRIMARY_NETWORK}' to VM"
    kcli add nic ovn-kubernetes-e2e -n "${PRIMARY_NETWORK}"

    echo "VM setup completed successfully"
}

if [[ "${CREATE_HYPERVISOR_VM:-false}" == "true" ]]; then
    echo "Starting VM creation on remote hypervisor"
    podman run --network host --rm -i \
        "${PODMAN_ENV[@]}" \
        "${PODMAN_MOUNTS[@]}" \
        --entrypoint /bin/bash \
        "quay.io/karmab/kcli" \
        -c "$(declare -f setup_vm_from_nested_container); setup_vm_from_nested_container"
    echo "VM creation completed"
else
    echo "Skipping VM creation (CREATE_HYPERVISOR_VM not set to 'true')"
fi
