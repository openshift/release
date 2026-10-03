#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Save exit code for JUnit XML generated in gather-must-gather.
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
# Resolve inputs
# ----------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/oc-mirror-disk-archive-dir" ]]; then
    echo "ERROR: ${SHARED_DIR}/oc-mirror-disk-archive-dir not found."
    echo "Run mirror-images-by-oc-mirror-to-disk before this step."
    exit 1
fi
REMOTE_WORKDIR=$(cat "${SHARED_DIR}/oc-mirror-disk-archive-dir")
echo "Disk archive on bastion: ${REMOTE_WORKDIR}"

if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo "ERROR: ${SHARED_DIR}/mirror_registry_url not found."
    exit 1
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "Target mirror registry: ${MIRROR_REGISTRY_HOST}"

BASTION_IP=$(cat "${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH}"

# ----------------------------------------------------------------
# Build a pull secret that authenticates to the local mirror registry
# and copy it to the bastion
# ----------------------------------------------------------------
REGISTRY_CRED=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | tr -d '\n' | base64 -w 0)
REMOTE_PULL_SECRET="/tmp/oc-mirror-push-secret.json"

# Disable tracing while handling the credential value.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
echo "{\"auths\":{\"${MIRROR_REGISTRY_HOST}\":{\"auth\":\"${REGISTRY_CRED}\"}}}" \
    | ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
      "cat > '${REMOTE_PULL_SECRET}' && chmod 600 '${REMOTE_PULL_SECRET}'"
$WAS_TRACING && set -x

# ----------------------------------------------------------------
# Determine oc-mirror version from the ImageSetConfiguration that
# the to-disk step recorded (we reuse the same binary version).
# The imageset config is already on the bastion; we detect the oc-mirror
# binary by re-downloading it from the same channel we used in to-disk.
# ----------------------------------------------------------------
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

REMOTE_RESULT_DIR="/tmp/oc-mirror-from-disk-result"
REMOTE_CONFIG="/tmp/oc-mirror-imageset-config.yaml"

# shellcheck disable=SC2087
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" bash -s -- \
    "${ARCH}" "${REMOTE_WORKDIR}" "${MIRROR_REGISTRY_HOST}" \
    "${REMOTE_PULL_SECRET}" "${REMOTE_RESULT_DIR}" "${REMOTE_CONFIG}" \
    << 'REMOTE_EOF'

ARCH="$1"
REMOTE_WORKDIR="$2"
MIRROR_REGISTRY_HOST="$3"
REMOTE_PULL_SECRET="$4"
REMOTE_RESULT_DIR="$5"
REMOTE_CONFIG="$6"

set -euo pipefail

# Detect the oc-mirror binary that was downloaded during the to-disk phase
# (it lives in a tmpdir that may have been cleaned up). Re-download from the
# same channel detected via the OCP version embedded in the working-dir metadata.
METADATA_FILE="${REMOTE_WORKDIR}/working-dir/release-filters/planning-result-v1.json"
if [[ -f "${METADATA_FILE}" ]]; then
    OCP_VERSION=$(python3 -c "
import json, sys
d = json.load(open('${METADATA_FILE}'))
# Extract version from the first platform release entry
releases = d.get('PlatformReleases', []) or d.get('release', []) or []
if releases:
    img = releases[0].get('TargetRef', releases[0].get('targetRef', ''))
    # version is typically embedded in the image tag after the colon
    tag = img.split(':')[-1] if ':' in img else ''
    print(tag)
" 2>/dev/null || echo "")
fi

# Fall back to latest if we cannot determine the version from metadata.
if [[ -z "${OCP_VERSION:-}" ]] || [[ ! "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+ ]]; then
    OC_MIRROR_CHANNEL="latest"
else
    MINOR=$(echo "${OCP_VERSION}" | grep -oP '^\d+\.\d+')
    if [[ "${OCP_VERSION}" =~ (nightly|ci|rc|ec) ]]; then
        STABLE_URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/stable-${MINOR}/"
        if curl -sf --head --connect-timeout 10 "${STABLE_URL}" >/dev/null 2>&1; then
            OC_MIRROR_CHANNEL="stable-${MINOR}"
        else
            OC_MIRROR_CHANNEL="latest"
        fi
    else
        OC_MIRROR_CHANNEL="${OCP_VERSION}"
    fi
fi
echo "oc-mirror channel for from-disk phase: ${OC_MIRROR_CHANNEL}"

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

mkdir -p "${REMOTE_RESULT_DIR}"

echo "Running oc-mirror disk-to-mirror: ${REMOTE_WORKDIR} -> docker://${MIRROR_REGISTRY_HOST}..."
"${OC_MIRROR_BIN}" \
    -c "${REMOTE_CONFIG}" \
    --from "file://${REMOTE_WORKDIR}" \
    "docker://${MIRROR_REGISTRY_HOST}" \
    --authfile "${REMOTE_PULL_SECRET}" \
    --dest-tls-verify=false \
    --v2

# Copy cluster-resource YAML files to a stable result dir for retrieval.
CLUSTER_RESOURCES_DIR="${REMOTE_WORKDIR}/working-dir/cluster-resources"
if [[ -d "${CLUSTER_RESOURCES_DIR}" ]]; then
    cp -r "${CLUSTER_RESOURCES_DIR}/." "${REMOTE_RESULT_DIR}/"
    echo "Cluster resource files:"
    ls -la "${REMOTE_RESULT_DIR}/"
else
    echo "WARNING: cluster-resources directory not found at ${CLUSTER_RESOURCES_DIR}"
    ls -la "${REMOTE_WORKDIR}/working-dir/" || true
fi

# Remove push credentials from bastion now that mirroring is done.
rm -f "${REMOTE_PULL_SECRET}"

REMOTE_EOF

# ----------------------------------------------------------------
# Retrieve the cluster-resource YAML files from the bastion
# ----------------------------------------------------------------
IDMS_REMOTE="${REMOTE_RESULT_DIR}/idms-oc-mirror.yaml"
ITMS_REMOTE="${REMOTE_RESULT_DIR}/itms-oc-mirror.yaml"

echo "Retrieving IDMS from bastion..."
scp ${SSH_OPTS} \
    "${BASTION_SSH_USER}@${BASTION_IP}:${IDMS_REMOTE}" \
    "${SHARED_DIR}/idms-oc-mirror.yaml"

echo "IDMS content:"
cat "${SHARED_DIR}/idms-oc-mirror.yaml"

# ITMS is optional — oc-mirror only produces it when tag-based mirrors are needed.
if ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
        "[[ -f '${ITMS_REMOTE}' ]]" 2>/dev/null; then
    echo "Retrieving ITMS from bastion..."
    scp ${SSH_OPTS} \
        "${BASTION_SSH_USER}@${BASTION_IP}:${ITMS_REMOTE}" \
        "${SHARED_DIR}/itms-oc-mirror.yaml"
    echo "ITMS content:"
    cat "${SHARED_DIR}/itms-oc-mirror.yaml"
fi

# ----------------------------------------------------------------
# Generate the install-config mirror patch from the IDMS
# ----------------------------------------------------------------
IDMS_FILE="${SHARED_DIR}/idms-oc-mirror.yaml"
ITMS_FILE="${SHARED_DIR}/itms-oc-mirror.yaml"
INSTALL_CONFIG_MIRROR_PATCH="${SHARED_DIR}/install-config-mirror.yaml.patch"

if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    KEY_NAME="imageDigestSources"
else
    KEY_NAME="imageContentSources"
fi

yq-v4 --prettyPrint eval-all \
    "{\"${KEY_NAME}\": .spec.imageDigestMirrors}" \
    "${IDMS_FILE}" > "${INSTALL_CONFIG_MIRROR_PATCH}"

if [[ -f "${ITMS_FILE}" ]]; then
    NEW_DATA=$(yq-v4 eval-all '.spec.imageTagMirrors' "${ITMS_FILE}") \
        yq-v4 eval-all ".${KEY_NAME} += env(NEW_DATA)" -i "${INSTALL_CONFIG_MIRROR_PATCH}"
fi

echo "install-config mirror patch:"
cat "${INSTALL_CONFIG_MIRROR_PATCH}"
