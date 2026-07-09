#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    ssh ${options} -i "${sshkey}" ${user}@${host} "${remote_cmd}"
}

function run_scp_to_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    scp ${options} -i "${sshkey}" ${src} ${user}@${host}:${dest}
}

echo "Updating cluster pull secret with ACR credentials..."

# Get bastion connection details
ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

echo "Bastion: ${bastion_user}@${bastion_dns}"

# Get ACR credentials from provision-acr-endpoint
if [[ ! -f "${SHARED_DIR}/acr_registry_creds" ]]; then
    echo "ERROR: ${SHARED_DIR}/acr_registry_creds not found"
    echo "The sandboxed-containers-operator-provision-acr-endpoint step should have created this file"
    exit 1
fi

# Get ACR login server
ACR_LOGIN_SERVER=$(cat "${SHARED_DIR}/acr_login_server" 2>/dev/null || echo "osccimirror.azurecr.io")
echo "ACR login server: ${ACR_LOGIN_SERVER}"

# Get ACR credentials and encode
acr_creds=$(cat "${SHARED_DIR}/acr_registry_creds")
acr_auth=$(echo -n "${acr_creds}" | base64 -w 0)

# Copy kubeconfig and ACR credentials to bastion
echo "Copying kubeconfig to bastion..."
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "${SHARED_DIR}/kubeconfig" "/tmp/kubeconfig"

echo "Setting up ACR pull secret update on bastion..."

# Create script on bastion to update pull secret
cat > /tmp/update-pull-secret.sh <<'EOF'
#!/bin/bash
set -e

export KUBECONFIG=/tmp/kubeconfig
ACR_LOGIN_SERVER="$1"
ACR_AUTH="$2"

echo "Extracting current cluster pull secret..."
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm

echo "Merging ACR credentials into pull secret..."
jq --arg server "${ACR_LOGIN_SERVER}" --arg auth "${ACR_AUTH}" \
  '.auths[$server] = {"auth": $auth}' \
  /tmp/.dockerconfigjson > /tmp/new-dockerconfigjson

echo "Updated pull secret with ACR credentials:"
jq '.auths | keys' /tmp/new-dockerconfigjson

echo "Updating cluster pull secret..."
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson

echo "Pull secret updated successfully"
EOF

run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/update-pull-secret.sh" "/tmp/update-pull-secret.sh"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "chmod +x /tmp/update-pull-secret.sh"

# Execute the update script on bastion
echo "Executing pull secret update on bastion..."
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/update-pull-secret.sh '${ACR_LOGIN_SERVER}' '${acr_auth}'"

echo "Waiting for MachineConfigPool to update..."
sleep 20

# Wait for MCP to finish updating (with timeout)
timeout=600
elapsed=0
while (( elapsed < timeout )); do
    if run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "KUBECONFIG=/tmp/kubeconfig oc wait mcp/worker --for condition=updated --timeout=1s" &>/dev/null; then
        echo "Worker MCP updated successfully"
        break
    fi
    if run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "KUBECONFIG=/tmp/kubeconfig oc wait mcp/master --for condition=updated --timeout=1s" &>/dev/null; then
        echo "Master MCP updated successfully"
        break
    fi
    sleep 20
    elapsed=$((elapsed + 20))
    echo "Waiting for MCP update... (${elapsed}/${timeout}s)"
done

if (( elapsed >= timeout )); then
    echo "WARNING: MCP update did not complete within ${timeout}s, continuing anyway"
else
    echo "MCP update completed successfully"
fi

echo "Pull secret updated successfully with ACR credentials"
