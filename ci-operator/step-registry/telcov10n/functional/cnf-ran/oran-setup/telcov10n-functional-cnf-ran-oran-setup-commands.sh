#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

process_inventory() {
  local directory="$1"
  local dest_file="$2"

  if [ -z "$directory" ]; then
    echo "Usage: process_inventory <directory> <dest_file>"
    return 1
  fi

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then
      continue
    fi
    local content
    content=$(cat "$filename")
    local varname
    varname=$(basename "${filename}")
    if [[ "$content" == *$'\n'* ]]; then
      echo "${varname}: |"
      echo "$content" | sed 's/^/  /'
    else
      echo "${varname}": \'"${content//\'/\'\'\'}"\'
    fi
  done > "${dest_file}"
}

# Temporary workaround: clone the fork so all O-RAN playbooks, roles, and
# ocp_operator_mirror fixes are available. Copy collections from the official
# image since the fork clone does not have them pre-installed.
# TODO: remove once openshift-kni/eco-ci-cd contains these changes and the
# image is rebuilt; then set ECO_CI_CD=/eco-ci-cd instead.
ECO_CI_CD="/tmp/eco-ci-cd-fork"
echo "Cloning eco-ci-cd fork (cnf-ran-oran-4.22)"
git clone --depth=1 --branch cnf-ran-oran-4.22 \
  https://github.com/rdiazcam/eco-ci-cd.git "${ECO_CI_CD}"
cp -r /eco-ci-cd/collections/. "${ECO_CI_CD}/collections/"

echo "Processing common group_vars"
mkdir -p "${ECO_CI_CD}/inventories/ocp-deployment/group_vars"

find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" "${ECO_CI_CD}/inventories/ocp-deployment/group_vars/$(basename "${dir}")"
done

echo "Copying host_vars"
mkdir -p "${ECO_CI_CD}/inventories/ocp-deployment/host_vars"

# In the full workflow hub-deploy writes bastion/master0 to SHARED_DIR.
# Fall back to the credential mounts for standalone rehearsal.
if [[ -f "${SHARED_DIR}/bastion" ]]; then
  cp "${SHARED_DIR}/bastion" "${ECO_CI_CD}/inventories/ocp-deployment/host_vars/bastion"
  cp "${SHARED_DIR}/master0" "${ECO_CI_CD}/inventories/ocp-deployment/host_vars/master0"
else
  echo "SHARED_DIR host_vars not found — using credential mounts (standalone run)"
  process_inventory /var/host_variables/kni-qe-129/bastion "${ECO_CI_CD}/inventories/ocp-deployment/host_vars/bastion"
  process_inventory /var/host_variables/kni-qe-129/master0 "${ECO_CI_CD}/inventories/ocp-deployment/host_vars/master0"
fi

if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}"

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

PROJECT_DIR="/tmp"
install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"

export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600
export ANSIBLE_HOST_KEY_CHECKING=False

# Policies repo defaults to the clusters repo when not explicitly set.
ORAN_POLICIES_REPO_URL="${ORAN_POLICIES_REPO_URL:-$ORAN_CLUSTERS_REPO_URL}"
ORAN_POLICIES_REPO_BRANCH="${ORAN_POLICIES_REPO_BRANCH:-$ORAN_CLUSTERS_REPO_BRANCH}"

# The O-RAN ztp-site-configs-ci repo uses a per-version layout
# (clustertemplates/<VERSION>, policytemplates/<VERSION>), so the ArgoCD source
# paths carry the version segment unless explicitly overridden.
ORAN_CLUSTERS_REPO_PATH="${ORAN_CLUSTERS_REPO_PATH:-clustertemplates/${VERSION}}"
ORAN_POLICIES_REPO_PATH="${ORAN_POLICIES_REPO_PATH:-policytemplates/${VERSION}}"

# The Keycloak "oran" realm export is Vault-sourced (client secrets + realm
# signing keys) and mounted read-only. Ansible's file lookup reads it on the
# controller (this pod), so pass the mounted path straight through. Do not print
# its contents.
ORAN_REALM_JSON_FILE="/var/oran-secrets/oran-realm.json"
if [[ ! -s "${ORAN_REALM_JSON_FILE}" ]]; then
  echo "ERROR: O-RAN realm export not found at ${ORAN_REALM_JSON_FILE}."
  echo "It must be provided by the telcov10n-oran-mtls-oauth Vault secret (key oran-realm.json)."
  exit 1
fi

cd "${ECO_CI_CD}"


# Phase 1: bring up the cluster PKI, Keycloak and mock-smo BEFORE installing the
# o-cloud-manager operator. The operator's webhook/operand pods only become
# healthy once the cluster PKI (cert-manager root-ca-issuer) exists, which is why
# it cannot be installed back in hub-config. The o2ims Inventory CR is deferred
# to phase 2 because it needs the operator's CRDs.
echo "O-RAN setup phase 1: cluster PKI, Keycloak, mock-smo"
ansible-playbook playbooks/ran/hub-sno-oran-setup.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    cluster_name=${CLUSTER_NAME} \
oran_realm_json_file=${ORAN_REALM_JSON_FILE} \
    oran_setup_firmware=false \
    oran_skip_oran_o2ims_inventory=true" -vv


# Deploy the Alertmanager that the o-cloud-manager alarms-server requires.
# Done after operator install so the CRDs are present; done before the Inventory
# CR so Alertmanager is already up when the alarms-server starts.
if [[ "${CONFIGURE_ACM_OBSERVABILITY}" == "true" ]]; then
  echo "Configuring ACM Observability (minimal Alertmanager for o-cloud-manager alarms-server)"
  ansible-playbook playbooks/ran/hub-sno-configure-acm-observability.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH}" -vv
fi

# Repoint the ZTP ArgoCD apps at the O-RAN clustertemplates/policytemplates.
# Done after o-cloud-manager install so the ClusterTemplate and related CRDs
# from clcm.openshift.io exist when ArgoCD syncs the clusters app.
echo "Configuring O-RAN GitOps (repointing ZTP ArgoCD apps at O-RAN templates)"
ansible-playbook playbooks/ran/hub-sno-configure-oran-gitops.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    oran_clusters_repo_url=${ORAN_CLUSTERS_REPO_URL} \
    oran_clusters_repo_branch=${ORAN_CLUSTERS_REPO_BRANCH} \
    oran_clusters_repo_path=${ORAN_CLUSTERS_REPO_PATH} \
    oran_policies_repo_url=${ORAN_POLICIES_REPO_URL} \
    oran_policies_repo_branch=${ORAN_POLICIES_REPO_BRANCH} \
    oran_policies_repo_path=${ORAN_POLICIES_REPO_PATH}" -vv

# Phase 2: create the o2ims Inventory CR (needs the operator CRDs) and, when
# requested, download the R750 firmware. PKI/Keycloak/mock-smo are already done.
echo "O-RAN setup phase 2: o2ims Inventory CR"
ansible-playbook playbooks/ran/hub-sno-oran-setup.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    cluster_name=${CLUSTER_NAME} \
oran_realm_json_file=${ORAN_REALM_JSON_FILE} \
    oran_setup_firmware=${ORAN_SETUP_FIRMWARE} \
    oran_firmware_server_model=${ORAN_FIRMWARE_SERVER_MODEL} \
    oran_skip_bootstrap_cluster_pki=true \
    oran_skip_keycloak=true \
    oran_skip_oran_mock_smo=true" -vv
