#!/bin/bash
set -euo pipefail

# TEMPORARY: combine #481 with this rehearsal; remove before merging #88130.
if [[ -n "${E2E_REHEARSAL_SOURCE_SHA}" ]]; then
    PR481_DIR=$(mktemp -d)
    git -C "${PR481_DIR}" init --quiet
    git -C "${PR481_DIR}" fetch --depth=1 https://github.com/rh-ecosystem-edge/openshift-dpf.git pull/481/head
    if [[ "$(git -C "${PR481_DIR}" rev-parse FETCH_HEAD)" != "${E2E_REHEARSAL_SOURCE_SHA}" ]]; then
        echo "ERROR: PR #481 has changed; update the reviewed source pin before rehearsing." >&2
        exit 1
    fi
    git -C "${PR481_DIR}" checkout --detach "${E2E_REHEARSAL_SOURCE_SHA}"
    echo "Testing openshift-dpf source: ${E2E_REHEARSAL_SOURCE_SHA}"
    cd "${PR481_DIR}"
fi

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
