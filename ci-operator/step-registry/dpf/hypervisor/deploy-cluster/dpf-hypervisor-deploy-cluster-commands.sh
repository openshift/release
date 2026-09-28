#!/bin/bash
set -euo pipefail

export PATH="/cli:${PATH}"

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

# Set up ~/.ssh for libvirt qemu+ssh:// connections from the Prow pod
mkdir -p ~/.ssh
cp /tmp/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
chmod 700 ~/.ssh
cat > ~/.ssh/config <<'SSHEOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
SSHEOF

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

echo "Deploying OpenShift cluster with DPF from Prow pod"
echo "Local working directory: ${WORK_DIR}"
echo "Remote host: ${REMOTE_HOST}"
echo "Cluster name: ${CLUSTER_NAME}"

# Verify remote work directory exists on bastion
echo "Verifying remote work directory exists..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -d ${REMOTE_MAIN_WORK_DIR}"; then
  echo "ERROR: Remote work directory ${REMOTE_MAIN_WORK_DIR} does not exist on ${REMOTE_HOST}"
  exit 1
fi

cd "${WORK_DIR}"

# Allow git operations despite UID mismatch (OpenShift runs as arbitrary UID)
git config --global --add safe.directory "${WORK_DIR}"

# Set up remote for fetching PRs
git remote set-url origin "${OPENSHIFT_DPF_GITHUB_REPO_URL}" 2>/dev/null \
  || git remote add origin "${OPENSHIFT_DPF_GITHUB_REPO_URL}"

# TEMPORARY: merge PR #269 for prow release integration (remove once merged)
echo "Fetching PR #269 (prow release integration)..."
git fetch origin pull/269/head:pr-269
NEED_PR_269=true

# If running in a PR job for openshift-dpf, checkout the PR branch
if [[ -n "${PULL_NUMBER:-}" ]] && [[ "${REPO_NAME:-}" == "openshift-dpf" ]]; then
  echo "PR job detected: checking out PR #${PULL_NUMBER}"
  if [[ "${PULL_NUMBER}" == "269" ]]; then
    git checkout pr-269
    NEED_PR_269=false
    echo "PR #269 is the PR under test, checked out directly"
  else
    git fetch origin "pull/${PULL_NUMBER}/head:pr-${PULL_NUMBER}"
    git checkout "pr-${PULL_NUMBER}"
    git rebase "origin/${OPENSHIFT_DPF_BRANCH}"
    echo "Successfully checked out PR #${PULL_NUMBER}"
  fi
fi

if [[ "${NEED_PR_269}" == "true" ]]; then
  git merge pr-269 --no-edit
  echo "PR #269 merged successfully"
fi

# Copy kubeconfig and .env to SHARED_DIR on exit so must-gather can reach
# the cluster even when the deployment fails partway through.
copy_kubeconfig() {
  echo "Attempting to copy kubeconfig to SHARED_DIR..."
  if [[ -f "${WORK_DIR}/kubeconfig-mno" ]]; then
    cp "${WORK_DIR}/kubeconfig-mno" "${SHARED_DIR}/kubeconfig"
    echo "Kubeconfig copied to \${SHARED_DIR}/kubeconfig"
  else
    echo "WARNING: Could not copy kubeconfig to SHARED_DIR (file may not exist yet)"
  fi

  echo "Attempting to copy .env to SHARED_DIR..."
  if [[ -f "${WORK_DIR}/.env" ]]; then
    cp "${WORK_DIR}/.env" "${SHARED_DIR}/.env"
    sed -i 's/^PAYLOAD_URL=.*$/PAYLOAD_URL=/' "${SHARED_DIR}/.env"
    echo ".env copied to \${SHARED_DIR}/.env"
  else
    echo "WARNING: Could not copy .env to SHARED_DIR (file may not exist yet)"
  fi
}
trap copy_kubeconfig EXIT

echo "Git repository state:"
git log --oneline -5

# SCP env.user file from bastion
echo "Fetching env.user_${CLUSTER_NAME} from bastion..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME}"; then
  echo "ERROR: File env.user_${CLUSTER_NAME} does not exist on bastion: ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME}"
  exit 1
fi
scp ${SSH_OPTS} "root@${REMOTE_HOST}:${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME}" .
echo "env.user_${CLUSTER_NAME} copied from bastion"

# Handle CI release payload
if [[ "${DPF_SKIP_CI_PAYLOAD:-false}" == "true" ]]; then
  PAYLOAD_URL=""
  echo "DPF_SKIP_CI_PAYLOAD is set; skipping CI release payload injection"
else
  PAYLOAD_URL="${RELEASE_IMAGE_LATEST:-}"
fi
echo "PAYLOAD_URL is ${PAYLOAD_URL:+set}${PAYLOAD_URL:-unset}"

# Merge CI registry credentials into the pull secret so the cluster can
# access the Prow-internal registry (registry.buildXX.ci.openshift.org).
if [[ -n "${PAYLOAD_URL}" ]]; then
  echo "Merging CI registry credentials into pull secret..."
  PULL_SECRET_SRC="${CLUSTER_PROFILE_DIR}/openshift-pull-secret"
  if [[ ! -f "${PULL_SECRET_SRC}" ]]; then
    echo "ERROR: ${PULL_SECRET_SRC} not found"
    exit 1
  fi
  cp "${PULL_SECRET_SRC}" /tmp/pull-secret.json
  oc registry login --to=/tmp/pull-secret.json

  # Place the merged pull secret where env.user expects it
  set -a
  # shellcheck source=/dev/null
  source "env.user_${CLUSTER_NAME}"
  set +a
  PS=${OPENSHIFT_PULL_SECRET:-openshift_pull.json}
  [[ "$PS" = /* ]] && LOCAL_PULL_SECRET="$PS" || LOCAL_PULL_SECRET="${WORK_DIR}/$PS"
  cp /tmp/pull-secret.json "${LOCAL_PULL_SECRET}"
  echo "Pull secret with CI registry credentials placed at ${LOCAL_PULL_SECRET}"
  rm -f /tmp/pull-secret.json
fi

# Generate the .env file
echo "Generating .env file from env.user_${CLUSTER_NAME}..."
export PAYLOAD_URL
set -a
# shellcheck source=/dev/null
source "env.user_${CLUSTER_NAME}"
set +a
make generate-env
echo ".env file generated successfully"

# Set LIBVIRT_HOST for remote VM management from the Prow pod
echo "LIBVIRT_HOST=${REMOTE_HOST}" >> .env
echo "Added LIBVIRT_HOST=${REMOTE_HOST} to .env"

# Update KUBECONFIG to local path
sed -i "s|KUBECONFIG=.*|KUBECONFIG=${WORK_DIR}/kubeconfig-mno|" .env
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

# Pick dynamic ports for the SSH reverse tunnel so parallel deployments
# (e.g. doca4 and doca8) sharing the same hypervisor don't collide
AI_PORT=$((RANDOM % 10000 + 20000))
IMAGE_PORT=$((AI_PORT + 1))
echo "AI_URL=http://${REMOTE_HOST}:${AI_PORT}" >> .env
echo "AI_ONPREM_PORT=${AI_PORT}" >> .env
echo "AI_ONPREM_IMAGE_PORT=${IMAGE_PORT}" >> .env
echo "Added AI_URL=http://${REMOTE_HOST}:${AI_PORT}, AI_ONPREM_PORT=${AI_PORT}, AI_ONPREM_IMAGE_PORT=${IMAGE_PORT} to .env"

echo "Copying .env to artifacts..."
cp .env "${ARTIFACT_DIR}/.env" || echo "WARNING: Failed to copy .env to artifacts"

# Start SSH reverse tunnel so VMs on the bastion network can reach the
# Assisted Installer running in this Prow pod
echo "Starting SSH reverse tunnel (AI API :${AI_PORT} -> :8090, image service :${IMAGE_PORT} -> :8888)..."
ssh ${SSH_OPTS} \
  -o ExitOnForwardFailure=yes \
  -R "0.0.0.0:${AI_PORT}:127.0.0.1:8090" \
  -R "0.0.0.0:${IMAGE_PORT}:127.0.0.1:8888" \
  root@${REMOTE_HOST} -N &
SSH_TUNNEL_PID=$!
cleanup() {
  copy_kubeconfig
  kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
}
trap 'cleanup' EXIT
sleep 2
if ! kill -0 ${SSH_TUNNEL_PID} 2>/dev/null; then
  echo "ERROR: SSH reverse tunnel failed to start"
  exit 1
fi
echo "SSH reverse tunnel started (PID: ${SSH_TUNNEL_PID})"

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

echo "Starting DPF deployment with 'make all'..."
if make all 2>&1 | tee "${ARTIFACT_DIR}/make_all_${datetime_string}.log"; then
  echo "DPF deployment completed successfully"
else
  echo "ERROR: DPF deployment failed"
  echo "Check deployment logs in artifacts"
  exit 1
fi

# Post-deployment: copy files back to bastion for tracking
echo "Copying deployment files back to bastion..."
ssh ${SSH_OPTS} root@${REMOTE_HOST} "mkdir -p ${REMOTE_WORK_DIR}/openshift-dpf"
scp ${SSH_OPTS} .env "root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/openshift-dpf/" || echo "WARNING: Failed to copy .env to bastion"
scp ${SSH_OPTS} kubeconfig-mno "root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/openshift-dpf/" 2>/dev/null || echo "WARNING: Failed to copy kubeconfig to bastion"

# Update last-openshift-dpf-dir.sh on bastion
echo "Updating last-openshift-dpf-dir.sh on bastion..."
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"; then
  ssh ${SSH_OPTS} root@${REMOTE_HOST} "sed -i 's|LAST_OPENSHIFT_DPF=.*|LAST_OPENSHIFT_DPF=${REMOTE_WORK_DIR}/openshift-dpf|' ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"
else
  ssh ${SSH_OPTS} root@${REMOTE_HOST} "echo 'LAST_OPENSHIFT_DPF=${REMOTE_WORK_DIR}/openshift-dpf' > ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"
fi
echo "Bastion tracking updated"
