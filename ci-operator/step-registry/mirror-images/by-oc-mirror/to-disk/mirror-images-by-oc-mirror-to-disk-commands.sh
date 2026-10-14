#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ "${MIRROR_BIN}" != "oc-mirror" ]]; then
  echo "MIRROR_BIN is '${MIRROR_BIN}', not 'oc-mirror' — skipping mirror-to-disk step."
  exit 0
fi

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Version comparison: returns 0 (true) if $2 < $1 (i.e. current version is before required)
function isPreVersion() {
  local required_ocp_version="$1"
  local isPre version
  version=$(oc version -o json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["clientVersion"]["gitVersion"])' | cut -d '.' -f1,2)
  echo "get oc version: ${version}"
  isPre=0
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${required_ocp_version}" "${version}" | sort --version-sort | head -n1)" = "${required_ocp_version}" ]; then
    isPre=1
  fi
  return $isPre
}

function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["digest"])')"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" \
            "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "User specified a custom payload for cluster install, overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
elif [[ "${USE_ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" == "true" ]]; then
  ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$(KUBECONFIG="" oc get is release -o jsonpath='{range .status.tags[*].items[*]}{.image}{" "}{.dockerImageReference}{"\n"}{end}' | grep "^$(echo "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" | sed 's/.*@//')" | awk '{print $2}')
  echo "User want the original payload for cluster install, overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interacts with the build farm.
KUBECONFIG="" oc registry login

run_command "which oc"
run_command "oc version --client"

# Detect architecture for oc-mirror download
ARCH=$(uname -m)
case ${ARCH} in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
esac

# oc-mirror is distributed via CGW which only publishes "latest"
oc_mirror_version="latest"
CGWURL="https://mirror.openshift.com/pub/cgw"
oc_mirror_download_dir=$(mktemp -d)
pushd "${oc_mirror_download_dir}"
echo "Downloading oc-mirror from ${CGWURL}/oc-mirror/${oc_mirror_version}/"
curl -fL --retry 5 --connect-timeout 30 -o oc-mirror.tar.gz \
    "${CGWURL}/oc-mirror/${oc_mirror_version}/oc-mirror-rhel9-linux-${ARCH}.tar.gz"

echo "Verifying oc-mirror.tar.gz integrity..."
curl -fL --retry 5 --connect-timeout 30 -o sha256sum.txt \
    "${CGWURL}/oc-mirror/${oc_mirror_version}/sha256sum.txt"
grep "oc-mirror-rhel9-linux-${ARCH}.tar.gz" sha256sum.txt | sed "s/oc-mirror-rhel9-linux-${ARCH}.tar.gz/oc-mirror.tar.gz/" | sha256sum -c - || {
    echo "ERROR: oc-mirror.tar.gz checksum verification failed"
    exit 1
}
echo "Checksum verification passed"

tar -xzf oc-mirror.tar.gz
chmod +x oc-mirror
oc_mirror_bin="${oc_mirror_download_dir}/oc-mirror"
popd

run_command "'${oc_mirror_bin}' version --output=yaml"

# Build combined pull secret (cluster pull-secret + mirror registry credentials)
combined_pull_secret=$(mktemp)
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | tr -d '\n' | base64 -w 0)

# private mirror registry host: <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c \
    'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' \
    > "${combined_pull_secret}"
KUBECONFIG="" oc registry login --to "${combined_pull_secret}"

# Set up workspace and pull-secret for oc-mirror
oc_mirror_workspace="/tmp/oc-mirror-workspace"
mkdir -p "${oc_mirror_workspace}"

# oc-mirror only respects ~/.docker/config.json -> ${XDG_RUNTIME_DIR}/containers/auth.json
mkdir -p "${XDG_RUNTIME_DIR}/containers/"
cp -f "${combined_pull_secret}" "${XDG_RUNTIME_DIR}/containers/auth.json"
unset REGISTRY_AUTH_PREFERENCE

# Write ImageSetConfiguration for mirror-to-disk
image_set_config="${oc_mirror_workspace}/image-set-config.yaml"
cat <<EOF | tee "${image_set_config}"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
EOF

# Build the mirror-to-disk command
# file:// destination (no docker:// target) = mirror-to-disk mode
mirrorCmd="${oc_mirror_bin} -c ${image_set_config} file://${oc_mirror_workspace} --v2"

# ref OCPBUGS-56009: payloads >= 4.19 that are unsigned need --ignore-release-signature
if ! isPreVersion "4.19" && ! check_signed "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ; then
    mirrorCmd="${mirrorCmd} --ignore-release-signature"
fi

echo "=== Running mirror-to-disk (Phase 1) ==="
run_command "${mirrorCmd}"

# Verify the workspace has the expected structure
if [[ ! -d "${oc_mirror_workspace}/working-dir" ]]; then
    echo "ERROR: oc-mirror workspace missing expected 'working-dir' directory after mirror-to-disk"
    ls -la "${oc_mirror_workspace}/"
    exit 1
fi
echo "Mirror-to-disk workspace contents:"
ls -la "${oc_mirror_workspace}/"
ls -la "${oc_mirror_workspace}/working-dir/" || true

# Ensure our UID is in /etc/passwd — required to SSH from this container
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"

echo "Bastion: ${BASTION_SSH_USER}@${BASTION_IP}"

# Transfer the oc-mirror workspace (archive) to the bastion
# The from-disk step will read the archive from this location on the bastion
echo "=== Transferring oc-mirror workspace to bastion ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "mkdir -p /tmp/oc-mirror-workspace"
rsync -e "ssh ${SSH_OPTS}" -av --progress \
    "${oc_mirror_workspace}/" \
    "${BASTION_SSH_USER}@${BASTION_IP}:/tmp/oc-mirror-workspace/"
echo "Workspace transfer complete."

# Transfer the oc-mirror binary to the bastion
# The from-disk step runs oc-mirror on the bastion (without internet access),
# so the binary must already be present there.
echo "=== Transferring oc-mirror binary to bastion ==="
scp ${SSH_OPTS} "${oc_mirror_bin}" "${BASTION_SSH_USER}@${BASTION_IP}:/tmp/oc-mirror"
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "chmod +x /tmp/oc-mirror && /tmp/oc-mirror version --output=yaml"
echo "Binary transfer complete."

# Record the workspace path on the bastion for the from-disk step
echo "/tmp/oc-mirror-workspace" > "${SHARED_DIR}/oc-mirror-workspace-path"
echo "Wrote SHARED_DIR/oc-mirror-workspace-path"

# Clean up local secrets
rm -f "${combined_pull_secret}"

echo "=== mirror-to-disk (Phase 1) complete ==="
echo "Archive staged on bastion at: /tmp/oc-mirror-workspace"
echo "oc-mirror binary staged on bastion at: /tmp/oc-mirror"
