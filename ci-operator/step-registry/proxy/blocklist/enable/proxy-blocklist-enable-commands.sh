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

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="ssh ${options} -i \"${sshkey}\" ${user}@${host} \"${remote_cmd}\""
    run_command "$cmd" || return 2
    return 0
}

function run_scp_to_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="scp ${options} -i \"${sshkey}\" ${src} ${user}@${host}:${dest}"
    run_command "$cmd" || return 2
    return 0
}

proxy_host_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
proxy_host_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

# Get blocklist from environment variable only
if [[ -z "${PROXY_BLOCKLIST}" ]]; then
    echo "Error: PROXY_BLOCKLIST environment variable is empty. Please specify domains to block."
    exit 1
fi

proxy_blocklist="${PROXY_BLOCKLIST}"
echo "Blocklist domains: ${proxy_blocklist}"

# Create script to update proxy configuration with blocklist
# This inserts the blocklist ACL and deny rule before the auth_param line
cat > "${ARTIFACT_DIR}/update_proxy_blocklist.sh" <<EOF
sed -i '/^auth_param basic program/i\acl blocklist dstdomain ${proxy_blocklist}' /srv/squid/etc/squid.conf &&
sed -i '/^auth_param basic program/i\http_access deny blocklist' /srv/squid/etc/squid.conf &&
systemctl restart squid.service || exit 1
exit 0
EOF

cp "${ARTIFACT_DIR}/update_proxy_blocklist.sh" ${SHARED_DIR}/

run_scp_to_remote ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${proxy_host_user} ${proxy_host_address} "${ARTIFACT_DIR}/update_proxy_blocklist.sh" '/tmp/update_proxy_blocklist.sh'
run_ssh_cmd ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${proxy_host_user} ${proxy_host_address} "chmod +x /tmp/update_proxy_blocklist.sh && sudo bash /tmp/update_proxy_blocklist.sh"

echo "Proxy blocklist configured successfully."

# Verify and save configuration
echo "Verifying blocklist configuration..."
run_ssh_cmd ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${proxy_host_user} ${proxy_host_address} "sudo grep -E '(acl blocklist|http_access deny blocklist)' /srv/squid/etc/squid.conf" || {
    echo "ERROR: Blocklist configuration not found in squid.conf"
    exit 1
}

echo "Blocklist configuration verified successfully."
