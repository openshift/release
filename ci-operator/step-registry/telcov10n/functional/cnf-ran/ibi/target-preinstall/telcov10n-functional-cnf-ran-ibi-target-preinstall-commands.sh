#!/bin/bash
set +x
set -euo pipefail
umask 077

cleanup() {
  rm -rf -- "${TEMP_DIR}"
}

validate_inputs() {
  : "${TARGET_CLUSTER_NAME:?TARGET_CLUSTER_NAME is required}"
  : "${VERSION:?VERSION is required}"
  : "${MIRROR_REGISTRY:?MIRROR_REGISTRY is required}"
  : "${ZTP_GIT_REPO:?ZTP_GIT_REPO is required}"
  : "${ZTP_GIT_BRANCH:?ZTP_GIT_BRANCH is required}"
  : "${TARGET_SPOKE_CLUSTER:?TARGET_SPOKE_CLUSTER is required}"
  if [[ ! -s "${SHARED_DIR}/ibi-seed-version" ]]; then
    echo "Missing seed version: the Prow ibi-seed-prepare step must record it before preinstall." >&2
    return 1
  fi
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
  if [[ ! "${SEED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ||
        "${SEED_VERSION}" != "${VERSION}."* ]]; then
    echo "Recorded seed version must be a full OpenShift version in the ${VERSION} release family." >&2
    return 1
  fi
  TARGET_SPOKE_NAME=$(printf '%s' "${TARGET_SPOKE_CLUSTER}" | tr -d "[]'\" ")
  [[ "${TARGET_SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

restore_target_inventory() {
  local name
  INVENTORY_PATH=/eco-ci-cd/inventories/ocp-deployment
  mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
  for name in all bastions; do
    cp "${SHARED_DIR}/target-${name}" "${INVENTORY_PATH}/group_vars/${name}"
  done
  cp "${SHARED_DIR}/target-bastion" "${INVENTORY_PATH}/host_vars/bastion"
}

create_work_directories() {
  TEMP_DIR=$(mktemp -d /tmp/ibi-preinstall.XXXXXX)
  trap cleanup EXIT
  WORK_DIR="/tmp/eco_gotests_ibi_preinstall/${TEMP_DIR##*/}"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-preinstall"
  mkdir -p "${REPORT_DIR}"
}

configure_ssh() {
  cp /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  chmod 600 "${TEMP_DIR}/ssh-key"

  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")
  [[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]

  SSH_OPTS=(
    -i "${TEMP_DIR}/ssh-key"
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=6
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

verify_installer_version() {
  local installer_output
  local installer_version

  echo "Checking the cached installer for OpenShift ${SEED_VERSION}."
  if ! installer_output=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "/opt/cache/${SEED_VERSION}/openshift-install version" 2>&1); then
    printf '%s\n' "${installer_output}" | redact_bastion >&2
    return 1
  fi

  installer_version=$(printf '%s\n' "${installer_output}" | awk '$1 == "openshift-install" { print $2 }')
  if [[ "${installer_version}" != "${SEED_VERSION}" ]]; then
    echo "Cached installer version '${installer_version}' does not match the recorded seed version '${SEED_VERSION}'." >&2
    return 1
  fi
}

prepare_launcher() {
  local site_config_url="${ZTP_GIT_REPO%.git}/-/raw/${ZTP_GIT_BRANCH}/${VERSION}/${TARGET_SPOKE_NAME}/clusterinstance"
  cd /eco-ci-cd
  ansible-playbook ./playbooks/ran/ibi-preinstall.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --tags setup \
    --extra-vars "ibi_hub_kubeconfig=/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_seed_image=${MIRROR_REGISTRY}/ibu/seed:${VERSION}" \
    --extra-vars "ibi_seed_version=${SEED_VERSION}" \
    --extra-vars "ibi_preinstall_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_cluster_instance_url=${site_config_url}/clusterinstance.yaml" \
    --extra-vars "ibi_config_template_url=${site_config_url}/preinstall-test/image-based-installation-config.yaml" \
    --extra-vars "ibi_openshift_install_path=/opt/cache/${SEED_VERSION}/openshift-install" \
    --extra-vars "ibi_work_dir=${WORK_DIR}" \
    --extra-vars '{
      "ibi_ssh_private_key_path": "/home/telcov10n/.ssh/id_rsa",
      "ibi_http_dir": "{{ http_store_path | default(\"/opt/http_store/data\") }}",
      "ibi_http_base_url": "http://{{ ansible_host }}:{{ share_http_iso_port }}",
      "eco_gotests_image": "quay.io/ocp-edge-qe/eco-gotests:latest",
      "ibi_test_timeout": "3h",
      "ibi_skip_tls_verify": true
    }' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/setup.log"
}

run_preinstall() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "cd '${WORK_DIR}' && exec ./eco-gotests-ibi-preinstall-run.sh" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/runner.log"
}

collect_reports() {
  scp -q -r "${SSH_OPTS[@]}" \
    "${BASTION_USER}@${BASTION_IP}:${WORK_DIR}/report" \
    "${REPORT_DIR}/" \
    2>&1 | redact_bastion
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping IBI target preinstall."
    return 0
  fi

  validate_inputs
  restore_target_inventory
  create_work_directories
  configure_ssh
  verify_installer_version
  prepare_launcher

  local run_rc=0
  local copy_rc=0

  run_preinstall || run_rc=$?
  collect_reports || copy_rc=$?

  # Preserve the execution failure after collecting reports.
  if (( run_rc != 0 )); then
    echo "IBI preinstall failed; exit status: ${run_rc}."
    return "${run_rc}"
  fi
  if (( copy_rc != 0 )); then
    echo "IBI preinstall reports could not be collected."
    return "${copy_rc}"
  fi

  echo "IBI preinstall execution and report collection completed."
}

main "$@"
