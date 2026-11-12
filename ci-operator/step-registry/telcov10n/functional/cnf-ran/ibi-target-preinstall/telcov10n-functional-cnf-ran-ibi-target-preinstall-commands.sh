#!/bin/bash
set +x
set -euo pipefail
umask 077

cleanup() {
  rm -rf -- "${TEMP_DIR}"
}

validate_inputs() {
  : "${TARGET_CLUSTER_NAME:?TARGET_CLUSTER_NAME is required}"
  # Consume the seed version and pinned inputs recorded by earlier steps.
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  SEED_DIGEST=$(<"${SHARED_DIR}/ibi-seed-digest")
  GIT_REVISION=$(<"${SHARED_DIR}/ibi-seed-git-revision")

  # The playbook validates the full version, registry and generated URLs.
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
  if [[ "${SEED_VERSION}" != "${VERSION}."* ]]; then
    echo "Recorded seed version must belong to the ${VERSION} release family." >&2
    return 1
  fi
  [[ "$SEED_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]
  [[ "$GIT_REVISION" =~ ^[a-f0-9]{40}$ ]]
  SEED_IMAGE="${MIRROR_REGISTRY}/ibu/seed@${SEED_DIGEST}"
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
  printf '%s\n' "${WORK_DIR}/report" > "${SHARED_DIR}/ibi-rp-preinstall-dir"
}

configure_ansible() {
  install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="${TEMP_DIR}/ssh-key"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_RETRIES=3
  export ANSIBLE_TIMEOUT=600

  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")
  [[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

prepare_launcher() {
  local site_config_url="${ZTP_GIT_REPO%.git}/-/raw/${GIT_REVISION}/${VERSION}/${TARGET_SPOKE_NAME}/clusterinstance"
  cd /eco-ci-cd
  ansible-playbook ./playbooks/ran/ibi-preinstall-stage.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --limit bastion \
    --extra-vars ibi_preinstall_phase=prepare \
    --extra-vars "ibi_hub_kubeconfig=/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_seed_image=${SEED_IMAGE}" \
    --extra-vars "ibi_seed_version=${SEED_VERSION}" \
    --extra-vars "ibi_preinstall_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_site_config_url=${site_config_url}" \
    --extra-vars "ibi_work_dir=${WORK_DIR}" \
    --extra-vars '{"ibi_skip_tls_verify":true}' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/setup.log"
}

run_preinstall() {
  local playbook_rc=0 console_rc=0 test_rc
  local console_log="${REPORT_DIR}/report/console.log"
  ansible-playbook ./playbooks/ran/ibi-preinstall-stage.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" --limit bastion \
    --extra-vars ibi_preinstall_phase=run \
    --extra-vars "ibi_work_dir=${WORK_DIR} ibi_report_dir=${REPORT_DIR}" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/execution.log" || playbook_rc=$?

  # The playbook collects artifacts even on failure; retain the full console in Prow.
  if [[ ! -f "$console_log" ]]; then console_log="${REPORT_DIR}/runner.log"; fi
  if [[ -f "$console_log" ]]; then
    redact_bastion < "$console_log" || console_rc=$?
  fi
  test -s "${REPORT_DIR}/execution-exit-code" || return 1
  test_rc=$(<"${REPORT_DIR}/execution-exit-code")
  [[ "$test_rc" =~ ^[0-9]+$ && "$test_rc" -le 255 ]] || return 1
  if (( test_rc != 0 )); then return "$test_rc"; fi
  if (( playbook_rc != 0 )); then return "$playbook_rc"; fi
  return "$console_rc"
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping IBI target preinstall."
    return 0
  fi

  validate_inputs
  restore_target_inventory
  create_work_directories
  configure_ansible
  prepare_launcher
  run_preinstall

  echo "IBI preinstall execution and report collection completed."
}

main "$@"
