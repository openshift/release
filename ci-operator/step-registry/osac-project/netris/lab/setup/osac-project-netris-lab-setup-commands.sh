#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ netris-lab setup ************"
echo "NETRIS_TEST_INFRA_REPO: ${NETRIS_TEST_INFRA_REPO}"
echo "NETRIS_TEST_INFRA_BRANCH: ${NETRIS_TEST_INFRA_BRANCH}"
echo "BUILD_ID: ${BUILD_ID}"
echo "-------------------------------------------"

# === Create ssh_config from ofcir-acquire output ===
IP=$(cat "${SHARED_DIR}/server-ip")
PORT=22
if [[ -f "${SHARED_DIR}/server-sshport" ]]; then
    PORT=$(<"${SHARED_DIR}/server-sshport")
fi

cat > "${SHARED_DIR}/ssh_config" <<SSHEOF
Host ci_machine
    HostName ${IP}
    User root
    Port ${PORT}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 90
    LogLevel ERROR
    IdentityFile ${CLUSTER_PROFILE_DIR}/packet-ssh-key
SSHEOF

echo "SSH config created for ${IP}:${PORT}"

# === Wait for SSH ===
echo "Waiting for SSH to be ready..."
for i in $(seq 30); do
    ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null && break
    echo "  attempt ${i}/30 - retrying in 10s..."
    sleep 10
done
ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null || {
    echo "ERROR: SSH to ${IP}:${PORT} never became available after 30 attempts"
    exit 1
}

# === Copy secrets to remote host ===
echo "Copying Netris license key..."
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    "${CLUSTER_PROFILE_DIR}/netris-license" ci_machine:/tmp/netris-license

echo "Copying AAP license..."
base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/license.zip ci_machine:/tmp/license.zip

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
echo "Copying pull-secret..."
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    "${CLUSTER_PROFILE_DIR}/pull-secret" ci_machine:/root/pull-secret

echo "Writing config file..."
cat > /tmp/config <<CONFIGEOF
[default]
lab_name = ci-${BUILD_ID}
aws_access_key_id = $(cat "${CLUSTER_PROFILE_DIR}/aws-access-key-id")
aws_secret_access_key = $(cat "${CLUSTER_PROFILE_DIR}/aws-secret-access-key")
aws_region = $(cat "${CLUSTER_PROFILE_DIR}/aws-region")
CONFIGEOF
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/config ci_machine:/tmp/config
$WAS_TRACING && set -x

# === Install prerequisites, clone repo, copy secrets, run make setup ===
echo "Setting up remote host..."
timeout -s 9 25m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF
set -o nounset
set -o errexit
set -o pipefail

dnf install -y ansible-core python3-pip make
pip3 install ansible

git clone --recurse-submodules ${NETRIS_TEST_INFRA_REPO} -b ${NETRIS_TEST_INFRA_BRANCH} /opt/netris-test-infra
cp /tmp/netris-license /opt/netris-test-infra/license.key
cp /tmp/license.zip /opt/netris-test-infra/license.zip
cp /tmp/config /opt/netris-test-infra/config

cd /opt/netris-test-infra
make setup
EOF

echo "netris-lab setup step finished successfully"
