#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Clone ibmcloud-openshift-provisioning (or compatible repo) using credentials from
# the ocp-addon / IBM Z vault mount, then run bash/csi-provisioner.sh to install NFS/CSI storage.

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig not found"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

CREDENTIALS_DIR="${OCP_ADDON_CREDENTIALS:-/etc/ocp-addons}"
GIT_URL_FILE="${CSI_PROVISIONER_GIT_URL_FILE:-${CREDENTIALS_DIR}/csi-provisioner-git-url}"
GIT_KEY_FILE="${CSI_PROVISIONER_GIT_KEY_FILE:-${CREDENTIALS_DIR}/csi_provisioner_git_key}}"
GIT_BRANCH="${CSI_PROVISIONER_GIT_BRANCH:-main}"
CLONE_DIR="${CSI_PROVISIONER_CLONE_DIR:-ocp-tools}"
SCRIPT_DIR="${CSI_PROVISIONER_SCRIPT_DIR:-bash}"
SCRIPT_NAME="${CSI_PROVISIONER_SCRIPT_NAME:-csi-provisioner.sh}"

echo "=== Current StorageClasses ==="
oc get storageclass -o wide || true

default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -n "${default_sc}" ]]; then
  echo "Default StorageClass already present: ${default_sc}. Skipping NFS/CSI provisioning."
  exit 0
fi

if [[ ! -f "${GIT_URL_FILE}" ]]; then
  echo "ERROR: Git repo URL file not found: ${GIT_URL_FILE}"
  echo "Expected vault secret ${CREDENTIALS_DIR} to contain csi-provisioner-git-url"
  exit 1
fi

if [[ ! -f "${GIT_KEY_FILE}" ]]; then
  echo "ERROR: Git SSH key file not found: ${GIT_KEY_FILE}"
  exit 1
fi

GIT_URL="$(tr -d '[:space:]' < "${GIT_URL_FILE}")"
if [[ -z "${GIT_URL}" ]]; then
  echo "ERROR: ${GIT_URL_FILE} is empty"
  exit 1
fi

ssh_key_string="$(cat "${GIT_KEY_FILE}")"
tmp_ssh_key="/tmp/csi-provisioner-git-ssh-key"
envsubst <<EOF >"${tmp_ssh_key}"
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 "${tmp_ssh_key}"

workdir="${ARTIFACT_DIR:-/tmp}/csi-provisioner-clone"
rm -rf "${workdir}"
mkdir -p "${workdir}"
cd "${workdir}"

echo "Cloning ${GIT_URL} (branch ${GIT_BRANCH})..."
GIT_SSH_COMMAND="ssh -i ${tmp_ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
  git clone -b "${GIT_BRANCH}" "${GIT_URL}" "${CLONE_DIR}"

script_path="${workdir}/${CLONE_DIR}/${SCRIPT_DIR}/${SCRIPT_NAME}"
if [[ ! -f "${script_path}" ]]; then
  echo "ERROR: ${script_path} not found after clone"
  find "${workdir}/${CLONE_DIR}" -maxdepth 3 -name "${SCRIPT_NAME}" || true
  exit 1
fi

chmod +x "${script_path}"
echo "Running ${script_path}..."
(
  cd "${workdir}/${CLONE_DIR}/${SCRIPT_DIR}"
  export KUBECONFIG
  ./"${SCRIPT_NAME}"
)

echo "=== StorageClasses after csi-provisioner.sh ==="
oc get storageclass -o wide

default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -z "${default_sc}" ]]; then
  echo "ERROR: csi-provisioner.sh finished but no default StorageClass was created"
  exit 1
fi

echo "Default StorageClass: ${default_sc}"
