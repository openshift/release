#!/bin/bash
set -euo pipefail

# Copy .env to working directory
cp "${SHARED_DIR}/.env" .env

echo "Setting up aicli offline token..."
install -d -m 700 "${HOME}/.aicli"
install -m 600 "${CLUSTER_PROFILE_DIR}/aicli-offlinetoken" "${HOME}/.aicli/offlinetoken.txt"
echo "aicli offline token configured"

echo "Setting up remote libvirt access..."
REMOTE_HOST=$(cat "${CLUSTER_PROFILE_DIR}/remote-host")
test -n "${REMOTE_HOST}"
install -d -m 700 "${HOME}/.ssh"
install -m 600 /dev/null "${HOME}/.ssh/id_rsa"
base64 --decode < "${CLUSTER_PROFILE_DIR}/private-key" > "${HOME}/.ssh/id_rsa"
printf '\n' >> "${HOME}/.ssh/id_rsa"
cat > "${HOME}/.ssh/config" <<EOF
Host ${REMOTE_HOST}
    IdentityFile ${HOME}/.ssh/id_rsa
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 30
    ServerAliveInterval 15
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
chmod 600 "${HOME}/.ssh/config"

# The hypervisor's copied .env selects local libvirt; Make must use the remote host.
export LIBVIRT_HOST="root@${REMOTE_HOST}"
sed -i '/^LIBVIRT_HOST=/d' .env
printf '\nLIBVIRT_HOST=%s\n' "${LIBVIRT_HOST}" >> .env

echo "Checking remote virsh access (120-second limit)..."
timeout 120 virsh -c "qemu+ssh://${LIBVIRT_HOST}/system" list --all > /dev/null
echo "Remote virsh access verified"

echo "Verifying cluster access..."
oc get nodes

echo "=== Running DPF Kubernetes e2e Tests ==="
[[ -n "${E2E_GO_LABEL_FILTER}" ]] && export E2E_GO_LABEL_FILTER
make validate-env-test-files
make generate-env-test
make test-go-e2e
