#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ ! -f "${SHARED_DIR}/bastion_private_address" ]]; then
  echo "bastion_private_address not found, skipping..."
  exit 0
fi

# Ensure our UID is in /etc/passwd (required for SSH)
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

BASTION_IP=$(< "${SHARED_DIR}/bastion_private_address")
if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
  BASTION_IP=$(< "${SHARED_DIR}/bastion_public_address")
fi
BASTION_SSH_USER=$(< "${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_OPTS="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

mirror_output="${SHARED_DIR}/mirror_output"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
cluster_mirror_conf_file="${SHARED_DIR}/local_registry_mirror_file.yaml"

# Set up env for oc commands
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"
unset KUBECONFIG

# Build pull secret with bastion registry credentials
new_pull_secret="/tmp/new_pull_secret"
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# Login to CI registry (build02) and add its credentials to pull secret
# This is needed so bastion can pull the release image from the CI registry
oc registry login
oc registry login --to "${new_pull_secret}"

# Copy pull secret with all credentials to bastion
scp ${SSH_OPTS} "${new_pull_secret}" ${BASTION_SSH_USER}@${BASTION_IP}:/tmp/pull_secret

# Get readable version from CI pod
readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "readable_version: ${readable_version}"

target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
target_release_image="${target_release_image_repo}:${readable_version}"
echo "target_release_image: ${target_release_image}"

# Use bastion's squid proxy (127.0.0.1:3128) to access quay.io
# proxy_private_url format: http://user:pass@bastion_ip:3128
# Replace bastion_ip with 127.0.0.1 since oc runs ON the bastion
PROXY_URL=""
if [[ -f "${SHARED_DIR}/proxy_private_url" ]]; then
  PROXY_URL=$(cat "${SHARED_DIR}/proxy_private_url" | sed "s|@${BASTION_IP}:|@127.0.0.1:|")
  # Verify squid is actually listening before using it
  if ssh ${SSH_OPTS} ${BASTION_SSH_USER}@${BASTION_IP} "nc -z 127.0.0.1 3128 2>/dev/null"; then
    echo "Using bastion squid proxy (credentials redacted)"
  else
    echo "Squid proxy not available, proceeding without proxy"
    PROXY_URL=""
  fi
fi

# Mirror release images from bastion using oc adm release mirror + squid proxy
# Bastion can access CI registry (build02) directly (same VMC network)
# Bastion uses its own squid proxy (127.0.0.1:3128) to access quay.io
# NO_PROXY excludes CI registry so it's accessed directly without proxy
echo "Mirroring release payload from bastion..."
MAX_ATTEMPTS=3
for attempt in $(seq 1 ${MAX_ATTEMPTS}); do
  echo "Attempt ${attempt}/${MAX_ATTEMPTS}"
  if ssh ${SSH_OPTS} ${BASTION_SSH_USER}@${BASTION_IP} \
    "HTTP_PROXY='${PROXY_URL}' HTTPS_PROXY='${PROXY_URL}' NO_PROXY='localhost,127.0.0.1,.vmc-ci.devcluster.openshift.com,registry.apps.build02.vmc.ci.openshift.org,.cloud-object-storage.appdomain.cloud,.s3.us-south.cloud-object-storage.appdomain.cloud' \
      oc adm release -a /tmp/pull_secret mirror \
      --from='${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}' \
      --to-release-image='${target_release_image}' \
      --to='${target_release_image_repo}' \
      --insecure=true --keep-manifest-list=true" | tee /tmp/mirror_output_raw 2>&1; then
    echo "Mirror succeeded."
    break
  fi
  if [[ ${attempt} -eq ${MAX_ATTEMPTS} ]]; then
    echo "Mirror failed after ${MAX_ATTEMPTS} attempts."
    exit 1
  fi
  sleep 30
done

# Extract imageDigestSources section for install-config patch
grep -A 1000 "^imageDigestSources:" /tmp/mirror_output_raw | \
  grep -B 1000 "^$\|^To use" | grep -v "^$\|^To use" > "${install_config_mirror_patch}" || true

if [[ ! -s "${install_config_mirror_patch}" ]]; then
  # Fallback: generate minimal IDMS manually
  cat > "${install_config_mirror_patch}" << EOF
imageDigestSources:
- mirrors:
  - ${target_release_image_repo}
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - ${target_release_image_repo}
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
fi

echo "Generated install-config-mirror.yaml.patch:"
cat "${install_config_mirror_patch}"

# Generate cluster mirror conf for upgrades
cat > "${cluster_mirror_conf_file}" << EOF
imageContentSources:
- mirrors:
  - ${target_release_image_repo}
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - ${target_release_image_repo}
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF

cp /tmp/mirror_output_raw "${mirror_output}" || true
rm -f "${new_pull_secret}"
