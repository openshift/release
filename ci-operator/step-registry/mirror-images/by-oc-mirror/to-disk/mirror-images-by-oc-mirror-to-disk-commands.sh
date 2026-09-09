#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Save exit code for JUnit XML generated in gather-must-gather.
# Pre-install config steps use exit code 100 on failure.
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Ensure our randomly-generated UID is in /etc/passwd so SSH works.
if ! whoami &>/dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and current UID has no entry; SSH may fail."
    fi
fi

# ----------------------------------------------------------------
# Resolve the payload image to mirror
# ----------------------------------------------------------------
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
    echo "Using custom payload: ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
fi

if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
    echo "ERROR: OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is empty."
    exit 1
fi
echo "Payload image: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# ----------------------------------------------------------------
# SSH connectivity to the bastion
# ----------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/bastion_public_address" ]]; then
    echo "ERROR: ${SHARED_DIR}/bastion_public_address not found. Run aws-provision-bastionhost first."
    exit 1
fi

BASTION_IP=$(cat "${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH}"

echo "Bastion: ${BASTION_SSH_USER}@${BASTION_IP}"

# ----------------------------------------------------------------
# Determine oc-mirror version to download on the bastion
# ----------------------------------------------------------------
# Login to the build farm so we can inspect the release image.
KUBECONFIG="" oc registry login

OCP_FULL_VERSION=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
    -o jsonpath='{.metadata.version}')
echo "Target OCP version: ${OCP_FULL_VERSION}"

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

if [[ "${OCP_FULL_VERSION}" =~ ^([0-9]+\.[0-9]+)\. ]]; then
    OCP_MINOR="${BASH_REMATCH[1]}"
    if [[ "${OCP_FULL_VERSION}" =~ (nightly|ci|rc|ec) ]]; then
        STABLE_URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/stable-${OCP_MINOR}/"
        if curl -sf --head --connect-timeout 10 "${STABLE_URL}" >/dev/null 2>&1; then
            OC_MIRROR_CHANNEL="stable-${OCP_MINOR}"
        else
            OC_MIRROR_CHANNEL="latest"
        fi
    else
        OC_MIRROR_CHANNEL="${OCP_FULL_VERSION}"
    fi
else
    OC_MIRROR_CHANNEL="latest"
fi
echo "oc-mirror channel: ${OC_MIRROR_CHANNEL}"

# ----------------------------------------------------------------
# Build the ImageSetConfiguration for the release payload
# ----------------------------------------------------------------
IMAGESET_CONFIG_FILE="${SHARED_DIR}/oc-mirror-imageset-config.yaml"
cat > "${IMAGESET_CONFIG_FILE}" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
EOF
echo "ImageSetConfiguration:"
cat "${IMAGESET_CONFIG_FILE}"

# ----------------------------------------------------------------
# Build the combined pull secret (build-farm creds + mirror registry)
# ----------------------------------------------------------------
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "Mirror registry: ${MIRROR_REGISTRY_HOST}"

REGISTRY_CRED=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | tr -d '\n' | base64 -w 0)
COMBINED_PULL_SECRET=$(mktemp)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" \
    | python3 -c "
import json, sys
j = json.load(sys.stdin)
j['auths']['${MIRROR_REGISTRY_HOST}'] = {'auth': '${REGISTRY_CRED}'}
print(json.dumps(j))
" > "${COMBINED_PULL_SECRET}"
KUBECONFIG="" oc registry login --to "${COMBINED_PULL_SECRET}"

# ----------------------------------------------------------------
# Transfer artefacts to the bastion and run oc-mirror there
# ----------------------------------------------------------------
REMOTE_WORKDIR="${DISK_ARCHIVE_DIR}"
REMOTE_CONFIG="/tmp/oc-mirror-imageset-config.yaml"
REMOTE_PULL_SECRET="/tmp/oc-mirror-pull-secret.json"

echo "Creating remote working directory ${REMOTE_WORKDIR} on bastion..."
# shellcheck disable=SC2029
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "mkdir -p '${REMOTE_WORKDIR}'"

echo "Copying ImageSetConfiguration to bastion..."
scp ${SSH_OPTS} "${IMAGESET_CONFIG_FILE}" \
    "${BASTION_SSH_USER}@${BASTION_IP}:${REMOTE_CONFIG}"

echo "Copying pull secret to bastion..."
scp ${SSH_OPTS} "${COMBINED_PULL_SECRET}" \
    "${BASTION_SSH_USER}@${BASTION_IP}:${REMOTE_PULL_SECRET}"
rm -f "${COMBINED_PULL_SECRET}"

# Download oc-mirror on the bastion and run the mirror-to-disk phase.
# We run on the bastion because it has better network throughput to the source
# registries and the disk archive stays local for the subsequent from-disk phase.
# Disable tracing for the block that handles the pull secret path.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
# shellcheck disable=SC2087
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" bash -s -- \
    "${OC_MIRROR_CHANNEL}" "${ARCH}" "${REMOTE_CONFIG}" \
    "${REMOTE_WORKDIR}" "${REMOTE_PULL_SECRET}" \
    << 'REMOTE_EOF'

OC_MIRROR_CHANNEL="$1"
ARCH="$2"
REMOTE_CONFIG="$3"
REMOTE_WORKDIR="$4"
REMOTE_PULL_SECRET="$5"

set -euo pipefail

echo "Downloading oc-mirror (channel: ${OC_MIRROR_CHANNEL}, arch: ${ARCH})..."
DOWNLOAD_DIR=$(mktemp -d)
curl -fL --retry 5 --connect-timeout 30 \
    -o "${DOWNLOAD_DIR}/oc-mirror.tar.gz" \
    "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_MIRROR_CHANNEL}/oc-mirror.tar.gz"

curl -fL --retry 5 --connect-timeout 30 \
    -o "${DOWNLOAD_DIR}/sha256sum.txt" \
    "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_MIRROR_CHANNEL}/sha256sum.txt"
grep "oc-mirror.tar.gz" "${DOWNLOAD_DIR}/sha256sum.txt" | sha256sum -c - || {
    echo "ERROR: oc-mirror checksum verification failed"
    exit 1
}

tar -xzf "${DOWNLOAD_DIR}/oc-mirror.tar.gz" -C "${DOWNLOAD_DIR}"
chmod +x "${DOWNLOAD_DIR}/oc-mirror"
OC_MIRROR_BIN="${DOWNLOAD_DIR}/oc-mirror"
"${OC_MIRROR_BIN}" version --output=yaml

echo "Running oc-mirror mirror-to-disk..."
"${OC_MIRROR_BIN}" \
    -c "${REMOTE_CONFIG}" \
    "file://${REMOTE_WORKDIR}" \
    --authfile "${REMOTE_PULL_SECRET}" \
    --dest-tls-verify=false \
    --v2

echo "Mirror-to-disk completed. Archive contents:"
du -sh "${REMOTE_WORKDIR}" || true

# Remove the pull secret from the bastion now that mirroring is done.
rm -f "${REMOTE_PULL_SECRET}"

REMOTE_EOF
$WAS_TRACING && set -x

# ----------------------------------------------------------------
# Record the archive location for the from-disk step
# ----------------------------------------------------------------
echo "${REMOTE_WORKDIR}" > "${SHARED_DIR}/oc-mirror-disk-archive-dir"
echo "Disk archive location recorded: ${REMOTE_WORKDIR}"
