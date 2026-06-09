#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ caas-agents setup ************"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "CLUSTER_TOOL_FLAVOR_NAME: ${CLUSTER_TOOL_FLAVOR_NAME}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "-------------------------------------------"

# Discover libvirt network: use CAAS_LIBVIRT_NETWORK if set (full-install path),
# otherwise find the cluster-tool network by flavor name (snapshot path).
if [[ -n "${CAAS_LIBVIRT_NETWORK}" ]]; then
    LIBVIRT_NETWORK="${CAAS_LIBVIRT_NETWORK}"
else
    LIBVIRT_NETWORK=$(ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
        "virsh net-list --name | grep '${CLUSTER_TOOL_FLAVOR_NAME}'" | head -1 | tr -d '[:space:]')
    [[ -z "${LIBVIRT_NETWORK}" ]] && { echo "ERROR: No libvirt network matching '${CLUSTER_TOOL_FLAVOR_NAME}' found"; exit 1; }
fi
echo "Libvirt network: ${LIBVIRT_NETWORK}"

# Kubeconfig: use CAAS_KUBECONFIG_PATH if set, otherwise try cluster-tool
# convention, otherwise discover via find (assisted-installer path).
if [[ -n "${CAAS_KUBECONFIG_PATH}" ]]; then
    KUBECONFIG_PATH="${CAAS_KUBECONFIG_PATH}"
else
    CT_PATH="/root/.kube/${CLUSTER_TOOL_FLAVOR_NAME}.kubeconfig"
    KUBECONFIG_PATH=$(ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
        "if [[ -f '${CT_PATH}' ]]; then echo '${CT_PATH}'; else find \${KUBECONFIG} -type f -print -quit 2>/dev/null; fi")
    [[ -z "${KUBECONFIG_PATH}" ]] && { echo "ERROR: Could not find kubeconfig on remote host"; exit 1; }
fi
echo "Kubeconfig: ${KUBECONFIG_PATH}"

# Extract setup-caas-agents.sh from the installer image and run it on the host.
# The script uses SSH_CONFIG to SSH into the host for DNS and VM steps.
# In CI the script already runs on the host, so SSH_CONFIG points to localhost.
echo "Extracting and running setup-caas-agents.sh..."
timeout -s 9 20m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${E2E_NAMESPACE}" \
    "${KUBECONFIG_PATH}" \
    "${LIBVIRT_NETWORK}" \
    "${OSAC_INSTALLER_IMAGE}" \
    <<'REMOTE_EOF'
set -euo pipefail

NAMESPACE="$1"
KUBECONFIG_PATH="$2"
LIBVIRT_NETWORK="$3"
INSTALLER_IMAGE="$4"

export KUBECONFIG="${KUBECONFIG_PATH}"

# Extract the installer scripts from the image
podman create --authfile /root/pull-secret --name installer-extract "${INSTALLER_IMAGE}" true
podman cp installer-extract:/installer/scripts /tmp/installer-scripts
podman rm installer-extract

# Create an SSH config that points to localhost (the script SSHes for DNS/VM steps)
cat > /tmp/localhost-ssh-config <<SSHCFG
Host ci_machine
    HostName 127.0.0.1
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCFG

INSTALLER_NAMESPACE="${NAMESPACE}" \
LIBVIRT_NETWORK="${LIBVIRT_NETWORK}" \
SSH_CONFIG="/tmp/localhost-ssh-config" \
    bash /tmp/installer-scripts/setup-caas-agents.sh
REMOTE_EOF

echo "CaaS agent infrastructure ready."
