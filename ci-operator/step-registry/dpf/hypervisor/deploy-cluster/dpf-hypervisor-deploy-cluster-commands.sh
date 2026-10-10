#!/bin/bash
set -euo pipefail

export PATH="/cli:${PATH}"

export HOME="/root/dpf-ci"

# A workflow can require an exact version handoff. Validate it before touching
# the hypervisor, independently of the workflow that supplied the request.
REQUESTED_DPF_OPENSHIFT_VERSION=""
if [[ -f "${SHARED_DIR}/dpf-openshift-version" ]]; then
  DPF_OPENSHIFT_VERSION="$(tr -d '[:space:]' < "${SHARED_DIR}/dpf-openshift-version")"
  if [[ -z "${DPF_OPENSHIFT_VERSION}" ]]; then
    echo "ERROR: ${SHARED_DIR}/dpf-openshift-version is empty"
    exit 1
  fi
  if [[ ! "${DPF_OPENSHIFT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
    echo "ERROR: invalid OpenShift version '${DPF_OPENSHIFT_VERSION}'"
    exit 1
  fi
  export DPF_OPENSHIFT_VERSION
  REQUESTED_DPF_OPENSHIFT_VERSION="${DPF_OPENSHIFT_VERSION}"
  DPF_SKIP_CI_PAYLOAD=true
  echo "Using OpenShift version ${DPF_OPENSHIFT_VERSION} from shared dir"
elif [[ "${DPF_REQUIRE_SHARED_OPENSHIFT_VERSION:-false}" == "true" ]]; then
  echo "ERROR: workflow requires ${SHARED_DIR}/dpf-openshift-version"
  exit 1
fi

echo "Checking access to SHARED_DIR ..."
echo "Testing SHARED_DIR" > ${SHARED_DIR}/testing.txt
ls -ltra ${SHARED_DIR}
cat ${SHARED_DIR}/testing.txt

CLUSTER_NAME=$(cat "${CLUSTER_PROFILE_DIR}/cluster-name")

# Configuration
REMOTE_HOST=$(cat ${CLUSTER_PROFILE_DIR}/remote-host)
echo "Remote host: ${REMOTE_HOST}"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat ${CLUSTER_PROFILE_DIR}/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# OpenSSH resolves ~ from getpwuid(), not $HOME. UID 1000 has no passwd
# entry, so ~/.ssh/config is never found. Work around this by placing an
# ssh wrapper early in PATH that injects the options every caller needs.
mkdir -p /tmp/ssh-wrap
cat > /tmp/ssh-wrap/ssh <<'SSHWRAP'
#!/bin/bash
exec /usr/bin/ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
SSHWRAP
chmod +x /tmp/ssh-wrap/ssh

# ipmitool is not in the dpf-ci image and the BMC management network is
# only reachable from the bastion. Proxy calls through SSH.
cat > /tmp/ssh-wrap/ipmitool <<IPMIWRAP
#!/bin/bash
exec /usr/bin/ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@${REMOTE_HOST} ipmitool "\$@"
IPMIWRAP
chmod +x /tmp/ssh-wrap/ipmitool

export PATH="/tmp/ssh-wrap:${PATH}"

# Set up SSH key and config for libvirt qemu+ssh:// connections.
# virsh uses libssh (not the openssh binary), and libssh resolves
# ~/.ssh from $HOME, so this config is found correctly.
mkdir -p ~/.ssh
cp /tmp/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
cat > ~/.ssh/config <<'SSHCFG'
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
SSHCFG
chmod 600 ~/.ssh/config
chmod 700 ~/.ssh

# Define SSH command with explicit options
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

# Test SSH connection
echo "Testing SSH connection to ${REMOTE_HOST}..."
if ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH connection successful'; then
  echo "SSH setup complete and tested successfully"
else
  echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
  echo "Debug information:"
  echo "- Checking if SSH key exists:"
  ls -la /tmp/id_rsa
  echo "- Testing SSH connectivity with verbose output:"
  ssh -v ${SSH_OPTS} root@${REMOTE_HOST} echo 'test' || true
  exit 1
fi

OPENSHIFT_DPF_GITHUB_REPO_URL="https://github.com/rh-ecosystem-edge/openshift-dpf.git"
REMOTE_MAIN_WORK_DIR="/root/${CLUSTER_NAME}/ci"
WORK_DIR="/root/dpf-ci"

# Check if target bastion is in maintenance mode
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f /root/${CLUSTER_NAME}/pause"; then
  echo "The cluster is in maintenance mode. Remove the file /root/${CLUSTER_NAME}/pause in the bastion host when the maintenance is over"
  exit 1
fi

REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/${CLUSTER_NAME}/ci/last-openshift-dpf-dir.sh"

datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")
REMOTE_WORK_DIR="${REMOTE_MAIN_WORK_DIR}/openshift-dpf-${datetime_string}"
REMOTE_OPENSHIFT_DPF_DIR="${REMOTE_WORK_DIR}/openshift-dpf"

echo "Deploying OpenShift cluster with DPF from Prow pod"
echo "Local working directory: ${WORK_DIR}"
echo "Remote host: ${REMOTE_HOST}"
echo "Remote tracking directory: ${REMOTE_OPENSHIFT_DPF_DIR}"
echo "Cluster name: ${CLUSTER_NAME}"
echo "Deploy make target: ${DPF_DEPLOY_MAKE_TARGET}"

# Verify remote work directory exists on bastion
echo "Verifying remote work directory exists..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -d ${REMOTE_MAIN_WORK_DIR}"; then
  echo "ERROR: Remote work directory ${REMOTE_MAIN_WORK_DIR} does not exist on ${REMOTE_HOST}"
  exit 1
fi

# Create tracking directory on bastion and update pointer early so files
# can be SCP'd back as soon as they become available (including on failure).
echo "Creating tracking directory on bastion: ${REMOTE_OPENSHIFT_DPF_DIR}"
ssh ${SSH_OPTS} root@${REMOTE_HOST} "mkdir -p ${REMOTE_OPENSHIFT_DPF_DIR}"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"; then
  ssh ${SSH_OPTS} root@${REMOTE_HOST} "sed -i 's|LAST_OPENSHIFT_DPF=.*|LAST_OPENSHIFT_DPF=${REMOTE_OPENSHIFT_DPF_DIR}|' ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"
else
  ssh ${SSH_OPTS} root@${REMOTE_HOST} "echo 'LAST_OPENSHIFT_DPF=${REMOTE_OPENSHIFT_DPF_DIR}' > ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"
fi
echo "Bastion tracking directory ready"

cd "${WORK_DIR}"

# Allow git operations despite UID mismatch (OpenShift runs as arbitrary UID)
git config --global --add safe.directory "${WORK_DIR}"
# Ignore permission changes from Containerfile's chmod 777
git config core.fileMode false

# Set up remote for fetching PRs
git remote set-url origin "${OPENSHIFT_DPF_GITHUB_REPO_URL}" 2>/dev/null \
  || git remote add origin "${OPENSHIFT_DPF_GITHUB_REPO_URL}"

# TEMPORARY: merge PR #269 for prow release integration (remove once merged)
echo "Fetching PR #269 (prow release integration)..."
git fetch origin pull/269/head:pr-269
git merge pr-269 --no-edit
echo "PR #269 merged successfully"

# Sync kubeconfigs and .env to SHARED_DIR and bastion. Called by the EXIT
# trap (so files are saved even on failure) and can also be called mid-run
# to push files as soon as they appear.
sync_artifacts() {
  local found_kubeconfig=false
  for kc in "${WORK_DIR}"/kubeconfig*; do
    [[ -f "$kc" ]] || continue
    found_kubeconfig=true
    local basename
    basename=$(basename "$kc")
    scp ${SSH_OPTS} "$kc" "root@${REMOTE_HOST}:${REMOTE_OPENSHIFT_DPF_DIR}/" 2>/dev/null \
      && echo "${basename} copied to bastion" \
      || echo "WARNING: Failed to copy ${basename} to bastion"
  done
  if $found_kubeconfig; then
    cp "${WORK_DIR}/kubeconfig.${CLUSTER_NAME}" "${SHARED_DIR}/kubeconfig" 2>/dev/null || true
  else
    echo "WARNING: No kubeconfig files found yet"
  fi

  if [[ -f "${WORK_DIR}/.env" ]]; then
    cp "${WORK_DIR}/.env" "${SHARED_DIR}/.env"
    sed -i 's/^PAYLOAD_URL=.*$/PAYLOAD_URL=/' "${SHARED_DIR}/.env"
    scp ${SSH_OPTS} "${WORK_DIR}/.env" "root@${REMOTE_HOST}:${REMOTE_OPENSHIFT_DPF_DIR}/" 2>/dev/null \
      && echo ".env copied to bastion" \
      || echo "WARNING: Failed to copy .env to bastion"
  fi
}
trap sync_artifacts EXIT

echo "Git repository state:"
git log --oneline -5

# Copy env.user from Vault cluster profile
echo "Copying env.user from Vault cluster profile..."
if [[ ! -f "${CLUSTER_PROFILE_DIR}/user-env" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/user-env not found"
  exit 1
fi
cp "${CLUSTER_PROFILE_DIR}/user-env" "env.user_${CLUSTER_NAME}"
echo "env.user_${CLUSTER_NAME} copied from Vault cluster profile"

# Set up aicli offline token for Red Hat AI console access
echo "Setting up aicli offline token..."
mkdir -p ~/.aicli
cp "${CLUSTER_PROFILE_DIR}/aicli-offlinetoken" ~/.aicli/offlinetoken.txt
echo "aicli offline token configured"

# Set up secrets from the Vault cluster profile
echo "Setting up secrets from Vault cluster profile..."
ssh-keygen -y -f /tmp/id_rsa > "${WORK_DIR}/ssh_key.pub"
ssh ${SSH_OPTS} root@${REMOTE_HOST} "cat /root/.ssh/id_rsa.pub" >> "${WORK_DIR}/ssh_key.pub" 2>/dev/null \
  && echo "Bastion public key appended to ssh_key.pub" \
  || echo "WARNING: Could not fetch bastion public key"
export SSH_KEY="${WORK_DIR}/ssh_key.pub"
echo "SSH public key(s) for VM injection: ${SSH_KEY}"

cp "${CLUSTER_PROFILE_DIR}/dpf-pull-secret" "${WORK_DIR}/dpf_pull_secret.json"
export DPF_PULL_SECRET="${WORK_DIR}/dpf_pull_secret.json"
echo "DPF pull secret copied from Vault cluster profile"

# Handle CI release payload
if [[ "${DPF_SKIP_CI_PAYLOAD:-false}" == "true" ]]; then
  PAYLOAD_URL=""
  echo "DPF_SKIP_CI_PAYLOAD is set; skipping CI release payload injection"
else
  PAYLOAD_URL="${RELEASE_IMAGE_LATEST:-}"
fi
echo "PAYLOAD_URL is ${PAYLOAD_URL:+set}${PAYLOAD_URL:-unset}"

# Copy the Vault pull secret into the writable working directory so it is
# available regardless of payload mode (env.user points at a bastion path
# that does not exist inside the pod).
PULL_SECRET_SRC="${CLUSTER_PROFILE_DIR}/openshift-pull-secret"
if [[ ! -f "${PULL_SECRET_SRC}" ]]; then
  echo "ERROR: ${PULL_SECRET_SRC} not found"
  exit 1
fi
LOCAL_PULL_SECRET="${WORK_DIR}/openshift_pull.json"
cp "${PULL_SECRET_SRC}" "${LOCAL_PULL_SECRET}"

# When injecting a CI release payload, merge Prow-internal registry
# credentials into the pull secret so the cluster can pull from
# registry.buildXX.ci.openshift.org.
if [[ -n "${PAYLOAD_URL}" ]]; then
  echo "Merging CI registry credentials into pull secret..."
  oc registry login --to="${LOCAL_PULL_SECRET}"
fi

export OPENSHIFT_PULL_SECRET="${LOCAL_PULL_SECRET}"
echo "Pull secret placed at ${LOCAL_PULL_SECRET}"

# Generate the .env file
echo "Generating .env file from env.user_${CLUSTER_NAME}..."
export PAYLOAD_URL
set -a
# shellcheck source=/dev/null
source "env.user_${CLUSTER_NAME}"
set +a
# Re-apply pod-local overrides that env.user may have clobbered
[[ -n "${LOCAL_PULL_SECRET:-}" ]] && export OPENSHIFT_PULL_SECRET="${LOCAL_PULL_SECRET}"
[[ -f "${WORK_DIR}/ssh_key.pub" ]] && export SSH_KEY="${WORK_DIR}/ssh_key.pub"
[[ -f "${WORK_DIR}/dpf_pull_secret.json" ]] && export DPF_PULL_SECRET="${WORK_DIR}/dpf_pull_secret.json"
if [[ -n "${REQUESTED_DPF_OPENSHIFT_VERSION}" ]]; then
  export DPF_OPENSHIFT_VERSION="${REQUESTED_DPF_OPENSHIFT_VERSION}"
  export PAYLOAD_URL=""
fi
if [[ -n "${DPF_OPENSHIFT_VERSION:-}" ]]; then
  export OPENSHIFT_VERSION="${DPF_OPENSHIFT_VERSION}"
fi
make generate-env
echo ".env file generated successfully"

# Set LIBVIRT_HOST for remote VM management from the Prow pod
# Include user since the pod runs as UID 1000, not root
echo "LIBVIRT_HOST=root@${REMOTE_HOST}" >> .env
echo "Added LIBVIRT_HOST=root@${REMOTE_HOST} to .env"

# Update KUBECONFIG to local path
sed -i "s|KUBECONFIG=.*|KUBECONFIG=${WORK_DIR}/kubeconfig.${CLUSTER_NAME}|" .env
echo "KUBECONFIG path updated in .env"

# Override dpf-hcp-provisioner-operator image if a CI-built override was provided
if [[ -f "${SHARED_DIR}/dpf-hcp-provisioner-operator-override" ]]; then
  OVERRIDE_IMAGE=$(cat "${SHARED_DIR}/dpf-hcp-provisioner-operator-override")
  if [[ -n "${OVERRIDE_IMAGE}" ]]; then
    OVERRIDE_REPO="${OVERRIDE_IMAGE%:*}"
    OVERRIDE_TAG="${OVERRIDE_IMAGE##*:}"
    echo "Overriding dpf-hcp-provisioner-operator image: repo=${OVERRIDE_REPO} tag=${OVERRIDE_TAG}"
    sed -i "s|DPF_HCP_PROVISIONER_OPERATOR_IMAGE_REPO=.*|DPF_HCP_PROVISIONER_OPERATOR_IMAGE_REPO=${OVERRIDE_REPO}|" .env
    sed -i "s|DPF_HCP_PROVISIONER_OPERATOR_IMAGE_TAG=.*|DPF_HCP_PROVISIONER_OPERATOR_IMAGE_TAG=${OVERRIDE_TAG}|" .env
    echo "dpf-hcp-provisioner-operator image override applied successfully"
  fi
fi

# When running with a CI payload the Assisted Installer runs locally as a
# podman container. Set up an SSH reverse tunnel so VMs on the bastion can
# reach it, and override AI_URL/ports accordingly. When DPF_SKIP_CI_PAYLOAD
# is set the AI is already available (public console or bastion-local podman)
# so none of this is needed.
if [[ -n "${PAYLOAD_URL}" ]]; then
  AI_PORT=$((RANDOM % 10000 + 20000))
  IMAGE_PORT=$((AI_PORT + 1))
  echo "AI_URL=http://${REMOTE_HOST}:${AI_PORT}" >> .env
  echo "AI_ONPREM_PORT=${AI_PORT}" >> .env
  echo "AI_ONPREM_IMAGE_PORT=${IMAGE_PORT}" >> .env
  echo "Added AI_URL=http://${REMOTE_HOST}:${AI_PORT}, AI_ONPREM_PORT=${AI_PORT}, AI_ONPREM_IMAGE_PORT=${IMAGE_PORT} to .env"
fi

echo "Copying .env to artifacts and bastion..."
sed -E '/^WORKER_[0-9]+_NAME=/!{ /^WORKER_[0-9]+_/d }' .env > "${ARTIFACT_DIR}/.env" || echo "WARNING: Failed to copy .env to artifacts"
sync_artifacts

if [[ -n "${PAYLOAD_URL}" ]]; then
  echo "Starting SSH reverse tunnel (AI API :${AI_PORT} -> :8090, image service :${IMAGE_PORT} -> :8888)..."
  ssh ${SSH_OPTS} \
    -o ExitOnForwardFailure=yes \
    -R "0.0.0.0:${AI_PORT}:127.0.0.1:8090" \
    -R "0.0.0.0:${IMAGE_PORT}:127.0.0.1:8888" \
    root@${REMOTE_HOST} -N &
  SSH_TUNNEL_PID=$!
  cleanup() {
    sync_artifacts
    kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
  }
  trap cleanup EXIT
  sleep 2
  if ! kill -0 ${SSH_TUNNEL_PID} 2>/dev/null; then
    echo "ERROR: SSH reverse tunnel failed to start"
    exit 1
  fi
  echo "SSH reverse tunnel started (PID: ${SSH_TUNNEL_PID})"
fi

# Run deployment locally
echo "Starting DPF deployment with 'make clean-all'..."
if make clean-all 2>&1 | tee "${ARTIFACT_DIR}/make_clean-all_${datetime_string}.log"; then
  echo "DPF pre-deployment clean-all completed successfully"
else
  echo "ERROR: DPF pre-deployment clean-all failed"
  exit 1
fi

echo "Sleeping for 300 seconds..."
sleep 300

echo "Starting DPF deployment with 'make ${DPF_DEPLOY_MAKE_TARGET}'..."
if make "${DPF_DEPLOY_MAKE_TARGET}" 2>&1 | tee "${ARTIFACT_DIR}/make_${DPF_DEPLOY_MAKE_TARGET}_${datetime_string}.log"; then
  echo "DPF deployment completed successfully"
else
  echo "ERROR: DPF deployment failed"
  echo "Check deployment logs in artifacts"
  exit 1
fi

echo "Deployment completed. Syncing kubeconfigs and .env to bastion..."
sync_artifacts
