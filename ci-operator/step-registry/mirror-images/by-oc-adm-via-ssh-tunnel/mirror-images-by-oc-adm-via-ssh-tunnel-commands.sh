#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

echo "=== Setting up SSH tunnel to vSphere bastion registry ==="

# Read bastion connection info
BASTION_IP=$(cat "${SHARED_DIR}/bastion_private_address")
BASTION_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

echo "Bastion IP: ${BASTION_IP}"
echo "Bastion User: ${BASTION_USER}"

# Ensure our UID is in /etc/passwd for SSH
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

# Start SSH tunnel in background
# Forward to bastion's localhost:5000 (where registry listens)
TUNNEL_LOCAL_PORT=5000
echo "Starting SSH tunnel: 127.0.0.1:${TUNNEL_LOCAL_PORT} -> bastion 127.0.0.1:5000"
ssh -f -N \
    -L "127.0.0.1:${TUNNEL_LOCAL_PORT}:127.0.0.1:5000" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=60 \
    -o ControlMaster=no \
    -i "${SSH_PRIV_KEY_PATH}" \
    "${BASTION_USER}@${BASTION_IP}"

# Give tunnel a moment to establish
sleep 5

# Verify tunnel is working
echo "Verifying SSH tunnel..."
for i in {1..10}; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:${TUNNEL_LOCAL_PORT}/v2/" 2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" || "${http_code}" == "401" ]]; then
        echo "SSH tunnel is working (HTTP ${http_code})"
        break
    fi
    echo "Tunnel not ready (HTTP ${http_code}), attempt ${i}/10"
    sleep 3
done

echo "=== SSH tunnel established, proceeding with mirroring ==="

# Unset proxy variables - CI pod has direct internet access
# Proxy may be set by bastion provision step, but CI pod cannot reach bastion's private proxy IP
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
echo "Proxy variables unset - CI pod will use direct internet connection"

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
cluster_mirror_conf_file="${SHARED_DIR}/local_registry_mirror_file.yaml"

# Use tunnel endpoint as mirror registry
MIRROR_REGISTRY_HOST="127.0.0.1:${TUNNEL_LOCAL_PORT}"
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

unset KUBECONFIG
oc registry login

readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "readable_version: $readable_version"

# Target release using localhost (tunnel)
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
target_release_image="${target_release_image_repo}:${readable_version}"

echo "target_release_image: $target_release_image"
echo "target_release_image_repo: $target_release_image_repo"

# Combine registry credentials
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"
oc registry login --to "${new_pull_secret}"

mirror_crd_type='icsp'
regex_keyword_1="imageContentSources"
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    mirror_crd_type='idms'
    regex_keyword_1="imageDigestSources"
fi

args=(
    --from="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
    --to-release-image="${target_release_image}"
    --to="${target_release_image_repo}"
    --insecure=true
)

if oc adm release mirror -h | grep -q -- --keep-manifest-list; then
    echo "Adding --keep-manifest-list to the mirror command."
    args+=(--keep-manifest-list=true)
fi

if oc adm release mirror -h | grep -q -- --print-mirror-instructions; then
    echo "Adding --print-mirror-instructions to the mirror command."
    args+=(--print-mirror-instructions="${mirror_crd_type}")
fi

cmd="oc adm release -a '${new_pull_secret}' mirror ${args[*]} | tee '${mirror_output}'"

MAX_ATTEMPTS=5
ATTEMPTS=0
SUCCESS=false
while [ "${SUCCESS}" = false ] && (( ATTEMPTS++ < MAX_ATTEMPTS )); do
  echo "Mirroring images attempt ${ATTEMPTS}/${MAX_ATTEMPTS}"
  if run_command "$cmd"; then
    echo "Mirroring images was successful in attempt $ATTEMPTS"
    SUCCESS=true
  else
    echo "Mirroring images attempt $ATTEMPTS failed. Trying again..."
    sleep 120
  fi
done

if [ $SUCCESS = false ]; then
  echo "Mirroring test images failed after $ATTEMPTS attempts, exiting ..."
  pkill -f "ssh.*127.0.0.1:${TUNNEL_LOCAL_PORT}:127.0.0.1:5000" || true
  exit 1
fi

line_num=$(grep -n "To use the new mirrored repository for upgrades" "${mirror_output}" | awk -F: '{print $1}')
install_end_line_num=$((line_num - 3))
upgrade_start_line_num=$((line_num + 2))
sed -n "/^${regex_keyword_1}/,${install_end_line_num}p" "${mirror_output}" > "${install_config_mirror_patch}"
sed -n "${upgrade_start_line_num},\$p" "${mirror_output}" > "${cluster_mirror_conf_file}"

# Update mirror URLs to use actual bastion DNS (not 127.0.0.1)
BASTION_MIRROR_URL=$(cat "${SHARED_DIR}/mirror_registry_url")
echo "Replacing 127.0.0.1:${TUNNEL_LOCAL_PORT} with ${BASTION_MIRROR_URL} in mirror config files"
sed -i "s|127\\.0\\.0\\.1:${TUNNEL_LOCAL_PORT}|${BASTION_MIRROR_URL}|g" "${install_config_mirror_patch}"
sed -i "s|127\\.0\\.0\\.1:${TUNNEL_LOCAL_PORT}|${BASTION_MIRROR_URL}|g" "${cluster_mirror_conf_file}"

run_command "cat '${install_config_mirror_patch}'"

# Kill SSH tunnel
echo "Cleaning up SSH tunnel"
pkill -f "ssh.*127.0.0.1:${TUNNEL_LOCAL_PORT}:127.0.0.1:5000" || true

rm -f "${new_pull_secret}"

echo "=== Mirroring via SSH tunnel completed successfully ==="
