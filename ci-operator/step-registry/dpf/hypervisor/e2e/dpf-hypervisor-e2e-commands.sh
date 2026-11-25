#!/bin/bash
set -euo pipefail

# Copy .env to working directory
cp "${SHARED_DIR}/.env" .env

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ ! -r "${KUBECONFIG}" ]]; then
    echo "ERROR: Management kubeconfig is missing or unreadable in SHARED_DIR" >&2
    exit 1
fi

echo "Setting up aicli offline token..."
install -d -m 700 "${HOME}/.aicli"
install -m 600 "${CLUSTER_PROFILE_DIR}/aicli-offlinetoken" "${HOME}/.aicli/offlinetoken.txt"
echo "aicli offline token configured"

# The copied .env can point to a pull secret that exists only on the hypervisor.
PROFILE_PULL_SECRET="${CLUSTER_PROFILE_DIR}/openshift-pull-secret"
if [[ ! -r "${PROFILE_PULL_SECRET}" ]]; then
    echo "ERROR: OpenShift pull secret is missing or unreadable in the cluster profile" >&2
    exit 1
fi
OPENSHIFT_PULL_SECRET=$(mktemp /tmp/dpf-openshift-pull.XXXXXX)
trap 'rm -f -- "${OPENSHIFT_PULL_SECRET}"' EXIT
is_pull_secret_json() {
    jq -es 'length == 1 and (.[0].auths | type == "object" and length > 0)' "$1" >/dev/null 2>&1
}
if is_pull_secret_json "${PROFILE_PULL_SECRET}"; then
    cat "${PROFILE_PULL_SECRET}" > "${OPENSHIFT_PULL_SECRET}"
elif ! base64 --decode < "${PROFILE_PULL_SECRET}" > "${OPENSHIFT_PULL_SECRET}" 2>/dev/null ||
     ! is_pull_secret_json "${OPENSHIFT_PULL_SECRET}"; then
    echo "ERROR: OpenShift pull secret in the cluster profile is not valid Docker auth JSON" >&2
    exit 1
fi
sed -i '/^OPENSHIFT_PULL_SECRET=/d' .env
printf '\nOPENSHIFT_PULL_SECRET=%s\n' "${OPENSHIFT_PULL_SECRET}" >> .env

echo "Setting up remote libvirt access..."
REMOTE_HOST=$(cat "${CLUSTER_PROFILE_DIR}/remote-host")
test -n "${REMOTE_HOST}"
install -d -m 700 "${HOME}/.ssh"
# Keep the hypervisor identity separate from aicli's default worker public key.
HYPERVISOR_SSH_KEY="${HOME}/.ssh/hypervisor_key"
install -m 600 /dev/null "${HYPERVISOR_SSH_KEY}"
base64 --decode < "${CLUSTER_PROFILE_DIR}/private-key" > "${HYPERVISOR_SSH_KEY}"
printf '\n' >> "${HYPERVISOR_SSH_KEY}"
cat > "${HOME}/.ssh/config" <<EOF
Host ${REMOTE_HOST}
    IdentityFile "${HYPERVISOR_SSH_KEY}"
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 30
    ServerAliveInterval 15
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
chmod 600 "${HOME}/.ssh/config"

# Explicitly load the job's SSH config for libvirt and the VM management helpers.
install -d -m 700 "${HOME}/.ssh/bin"
cat > "${HOME}/.ssh/bin/ssh" <<EOF
#!/bin/bash
exec /usr/bin/ssh -F "${HOME}/.ssh/config" "\$@"
EOF
chmod 700 "${HOME}/.ssh/bin/ssh"
export PATH="${HOME}/.ssh/bin:${PATH}"

export LIBVIRT_HOST="root@${REMOTE_HOST}"

echo "Checking remote virsh access (120-second limit)..."
timeout 120 virsh -c "qemu+ssh://${LIBVIRT_HOST}/system" list --all > /dev/null
echo "Remote virsh access verified"

# aicli reads the worker public key from its default location in this container.
REMOTE_WORKER_SSH_KEY=$(sed -n 's/^SSH_KEY=//p' .env)
if [[ "${REMOTE_WORKER_SSH_KEY}" != /*.pub || "${REMOTE_WORKER_SSH_KEY}" == *$'\n'* ]]; then
    echo "ERROR: The deployment SSH_KEY must be a single absolute path to a public key" >&2
    exit 1
fi
WORKER_SSH_KEY="${HOME}/.ssh/id_rsa.pub"
if ! timeout 120 ssh "${LIBVIRT_HOST}" "cat -- $(printf '%q' "${REMOTE_WORKER_SSH_KEY}")" > "${WORKER_SSH_KEY}" ||
   ! ssh-keygen -l -f "${WORKER_SSH_KEY}" >/dev/null 2>&1; then
    echo "ERROR: Could not load the worker SSH public key from the hypervisor" >&2
    exit 1
fi

# Nested Make targets reload .env for worker provisioning and cleanup.
sed -i -e '/^LIBVIRT_HOST=/d' -e '/^KUBECONFIG=/d' -e '/^SSH_KEY=/d' .env
printf '\nLIBVIRT_HOST=%s\nKUBECONFIG=%s\nSSH_KEY=%s\n' \
    "${LIBVIRT_HOST}" "${KUBECONFIG}" "${WORKER_SSH_KEY}" >> .env

echo "Verifying cluster access..."
oc get nodes

echo "=== Running DPF Kubernetes e2e Tests ==="
[[ -n "${E2E_GO_LABEL_FILTER}" ]] && export E2E_GO_LABEL_FILTER
make validate-env-test-files
make generate-env-test
make test-go-e2e
