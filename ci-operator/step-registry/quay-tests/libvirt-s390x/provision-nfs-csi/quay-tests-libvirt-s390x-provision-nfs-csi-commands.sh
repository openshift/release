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

export GIT_SSH_COMMAND="ssh -i ${tmp_ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"

configure_git_ssh_urls() {
  local git_url="$1"
  local host

  host="$(echo "${git_url}" | sed -nE 's#^(git@|https?://)([^/:]+).*#\2#p')"
  if [[ -n "${host}" ]]; then
    git config --global --add "url.git@${host}:".insteadOf "https://${host}/"
    git config --global --add "url.git@${host}:".insteadOf "http://${host}/"
  fi
  # Submodule URLs in ocp-tools often use this host even when the parent uses SSH.
  git config --global --add url.git@gitlab.cee.redhat.com:.insteadOf https://gitlab.cee.redhat.com/
  git config --global --add url.git@github.ibm.com:.insteadOf https://github.ibm.com/
}

workdir="${ARTIFACT_DIR:-/tmp}/csi-provisioner-clone"
rm -rf "${workdir}"
mkdir -p "${workdir}"
cd "${workdir}"

configure_git_ssh_urls "${GIT_URL}"

echo "Cloning ${GIT_URL} (branch ${GIT_BRANCH})..."
git clone -b "${GIT_BRANCH}" "${GIT_URL}" "${CLONE_DIR}"

repo_root="${workdir}/${CLONE_DIR}"
cd "${repo_root}"

echo "Initializing submodules over SSH (rewriting https:// URLs)..."
git submodule sync --recursive
git submodule update --init --recursive

script_path="${repo_root}/${SCRIPT_DIR}/${SCRIPT_NAME}"
libs_path="${repo_root}/libs/__sources__.bash"

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

# ocp-tools keeps CSI manifests at repo-root csi/, while csi-provisioner.sh
# expects them beside the script under bash/csi/.
manifest_dir="${CSI_PROVISIONER_MANIFEST_DIR:-}"
if [[ -z "${manifest_dir}" ]]; then
  if [[ -d "${repo_root}/csi" ]]; then
    manifest_dir="${repo_root}/csi"
  elif [[ -d "${repo_root}/${SCRIPT_DIR}/csi" ]]; then
    manifest_dir="${repo_root}/${SCRIPT_DIR}/csi"
  fi
fi

if [[ -z "${manifest_dir}" || ! -d "${manifest_dir}" ]]; then
  echo "ERROR: CSI manifest directory not found"
  echo "Checked: ${repo_root}/csi and ${repo_root}/${SCRIPT_DIR}/csi"
  exit 1
fi

script_csi_dir="${repo_root}/${SCRIPT_DIR}/csi"
if [[ "${manifest_dir}" != "${script_csi_dir}" && ! -e "${script_csi_dir}" ]]; then
  echo "Linking ${script_csi_dir} -> ${manifest_dir} for csi-provisioner.sh"
  ln -sfn "${manifest_dir}" "${script_csi_dir}"
fi

required_manifests=(
  namespace.yaml
  external-provisioner-rbac.yaml
  csi-driver-hostpath-provisioner.yaml
  kubevirt-hostpath-security-constraints-csi.yaml
  csi-sc.yaml
  csi-driver/csi-kubevirt-hostpath-provisioner.yaml
)

echo "=== Pre-flight checks ==="
echo "Script: ${script_path}"
echo "Libs:   ${libs_path}"
echo "CSI manifests: ${manifest_dir}"
missing_manifests=()
for manifest in "${required_manifests[@]}"; do
  if [[ ! -f "${manifest_dir}/${manifest}" ]]; then
    missing_manifests+=("${manifest}")
  fi
done
if [[ ${#missing_manifests[@]} -gt 0 ]]; then
  echo "ERROR: missing CSI manifest files under ${manifest_dir}:"
  printf '  - %s\n' "${missing_manifests[@]}"
  exit 1
fi
echo "All required CSI manifest files are present."

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

CSI_STORAGE_CLASS="${CSI_PROVISIONER_STORAGE_CLASS:-crc-csi-hostpath-provisioner}"

default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -z "${default_sc}" ]]; then
  if ! oc get storageclass "${CSI_STORAGE_CLASS}" >/dev/null 2>&1; then
    echo "ERROR: StorageClass ${CSI_STORAGE_CLASS} not found after csi-provisioner.sh"
    exit 1
  fi
  echo "No default StorageClass found; annotating ${CSI_STORAGE_CLASS} as default..."
  for existing_default in $(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    oc annotate storageclass "${existing_default}" storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true
  done
  oc annotate storageclass "${CSI_STORAGE_CLASS}" storageclass.kubernetes.io/is-default-class=true --overwrite
  default_sc="${CSI_STORAGE_CLASS}"
fi

if [[ -z "${default_sc}" ]]; then
  echo "ERROR: failed to set a default StorageClass"
  exit 1
fi

echo "Default StorageClass: ${default_sc}"
