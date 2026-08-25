#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Clone ocp-tools (or compatible repo) using credentials from the ocp-addons-key
# vault mount, then run bash/csi-provisioner.sh to install NFS/CSI storage.

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig not found"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

CREDENTIALS_DIR="${OCP_ADDON_CREDENTIALS:-/etc/ocp-addons}"
GIT_URL_FILE="${CSI_PROVISIONER_GIT_URL_FILE:-${CREDENTIALS_DIR}/csi-provisioner-git-url}"
GIT_KEY_FILE="${CSI_PROVISIONER_GIT_KEY_FILE:-${CREDENTIALS_DIR}/${CSI_PROVISIONER_GIT_KEY:-csi_provisioner_git_key}}"
CLONE_DIR="${CSI_PROVISIONER_CLONE_DIR:-ocp-tools}"
SCRIPT_DIR="${CSI_PROVISIONER_SCRIPT_DIR:-bash}"
SCRIPT_NAME="${CSI_PROVISIONER_SCRIPT_NAME:-csi-provisioner.sh}"
BRANCH_FILE="${CREDENTIALS_DIR}/CSI_PROVISIONER_GIT_BRANCH"

# Prefer vault branch file; allow explicit CSI_PROVISIONER_GIT_BRANCH env override.
GIT_BRANCH="main"
if [[ -f "${BRANCH_FILE}" ]]; then
  GIT_BRANCH="$(tr -d '[:space:]' < "${BRANCH_FILE}")"
fi
if [[ -n "${CSI_PROVISIONER_GIT_BRANCH:-}" ]]; then
  GIT_BRANCH="${CSI_PROVISIONER_GIT_BRANCH}"
fi
if [[ -z "${GIT_BRANCH}" ]]; then
  echo "ERROR: git branch is empty (check ${BRANCH_FILE} or CSI_PROVISIONER_GIT_BRANCH)"
  exit 1
fi

echo "=== Current StorageClasses ==="
oc get storageclass -o wide || true

default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -n "${default_sc}" ]]; then
  echo "Default StorageClass already present: ${default_sc}. Skipping NFS/CSI provisioning."
  exit 0
fi

echo "=== Credential mount (${CREDENTIALS_DIR}) ==="
if [[ -d "${CREDENTIALS_DIR}" ]]; then
  find "${CREDENTIALS_DIR}" -type f | sort || true
else
  echo "ERROR: credentials mount ${CREDENTIALS_DIR} does not exist (secret not mounted?)"
  exit 1
fi

if [[ ! -f "${GIT_URL_FILE}" ]]; then
  echo "ERROR: Git repo URL file not found: ${GIT_URL_FILE}"
  echo "Expected ocp-addons-key secret keys at ${CREDENTIALS_DIR}/csi-provisioner-git-url"
  echo "and ${CREDENTIALS_DIR}/csi_provisioner_git_key (see listing above)."
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
if grep -q 'BEGIN .* PRIVATE KEY' "${GIT_KEY_FILE}"; then
  cp "${GIT_KEY_FILE}" "${tmp_ssh_key}"
else
  cat >"${tmp_ssh_key}" <<EOF
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}
-----END OPENSSH PRIVATE KEY-----
EOF
fi
chmod 0600 "${tmp_ssh_key}"

workdir="${ARTIFACT_DIR:-/tmp}/csi-provisioner-clone"
rm -rf "${workdir}"
mkdir -p "${workdir}"
cd "${workdir}"

echo "Cloning ${GIT_URL} (branch ${GIT_BRANCH})..."
GIT_SSH_COMMAND="ssh -i ${tmp_ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
  git clone --recurse-submodules -b "${GIT_BRANCH}" "${GIT_URL}" "${CLONE_DIR}"

repo_root="${workdir}/${CLONE_DIR}"
cd "${repo_root}"
git submodule update --init --recursive || true

script_path="${repo_root}/${SCRIPT_DIR}/${SCRIPT_NAME}"
libs_path="${repo_root}/libs/__sources__.bash"
manifest_dir="${repo_root}/${SCRIPT_DIR}/csi"

echo "=== Cloned repository layout ==="
find "${repo_root}" -maxdepth 3 \( -type f -o -type d \) | sort | head -200 || true

if [[ ! -f "${script_path}" ]]; then
  echo "ERROR: ${script_path} not found after clone"
  find "${repo_root}" -name "${SCRIPT_NAME}" || true
  exit 1
fi

if [[ ! -f "${libs_path}" ]]; then
  echo "ERROR: ${libs_path} not found after clone"
  echo "The cloned branch (${GIT_BRANCH}) is missing repo libs/. Check CSI_PROVISIONER_GIT_BRANCH in vault."
  exit 1
fi

if [[ ! -d "${manifest_dir}" ]]; then
  echo "ERROR: ${manifest_dir} not found after clone"
  echo "The cloned branch (${GIT_BRANCH}) is missing CSI manifests under ${SCRIPT_DIR}/csi/."
  exit 1
fi

chmod +x "${script_path}"
echo "Running ${script_path} from repo root ${repo_root}..."

# shellcheck disable=SC1090
source "${libs_path}"

export KUBECONFIG
export REPO_ROOT="${repo_root}"
export OCP_TOOLS_ROOT="${repo_root}"
export CSI_LIBVIRT_CI="true"

(
  cd "${repo_root}"
  bash "${script_path}"
)

echo "=== StorageClasses after csi-provisioner.sh ==="
oc get storageclass -o wide

default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -z "${default_sc}" ]]; then
  echo "ERROR: csi-provisioner.sh finished but no default StorageClass was created"
  exit 1
fi

echo "Default StorageClass: ${default_sc}"
