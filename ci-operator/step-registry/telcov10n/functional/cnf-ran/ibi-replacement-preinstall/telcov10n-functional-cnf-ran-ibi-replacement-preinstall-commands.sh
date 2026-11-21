#!/bin/bash
set +x
set -euo pipefail
umask 077

cleanup() {
  local rc=$?
  trap - EXIT
  rm -rf -- "${TEMP_DIR}" || rc=1
  exit "${rc}"
}

restore_seed_inventory() {
  local name
  INVENTORY_PATH=/eco-ci-cd/inventories/ocp-deployment
  mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
  for name in all bastions; do
    cp "${SHARED_DIR}/seed-${name}" "${INVENTORY_PATH}/group_vars/${name}"
  done
  cp "${SHARED_DIR}/seed-bastion" "${INVENTORY_PATH}/host_vars/bastion"
}

create_work_directories() {
  TEMP_DIR=$(mktemp -d /tmp/ibi-replacement-preinstall.XXXXXX)
  trap cleanup EXIT
  local subdir="${TEMP_DIR##*/}"
  WORK_DIR="/tmp/eco_gotests_ibi_preinstall/${subdir}"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-replacement-preinstall"
  HTTP_SUBDIR="${subdir}"
  mkdir -p "${REPORT_DIR}"
  printf '%s\n' "${WORK_DIR}/report" > "${SHARED_DIR}/ibi-rp-preinstall_replacement-dir"
}

read_seed_inputs() {
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  SEED_DIGEST=$(<"${SHARED_DIR}/ibi-seed-digest")
  GIT_REVISION=$(<"${SHARED_DIR}/ibi-seed-git-revision")
}

configure_ansible() {
  local bastion_identity
  install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="${TEMP_DIR}/ssh-key"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_RETRIES=3
  export ANSIBLE_TIMEOUT=600
  export ANSIBLE_REMOTE_TEMP=/tmp

  # Resolve inventory precedence without printing private inventory variables.
  bastion_identity=$(
    exec 2>"${TEMP_DIR}/inventory.log" || exit 1
    ansible-inventory -i "${INVENTORY_PATH}/build-inventory.py" --host bastion |
      jq -er '[.ansible_host, .ansible_user] | join(" ")'
  )

  read -r BASTION_IP BASTION_USER <<< "${bastion_identity}"
  [[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//"${BASTION_USER}@${BASTION_IP}"/<bastion>}"
    line="${line//"${BASTION_IP}"/<bastion>}"
    printf '%s\n' "${line}"
  done
}

run_preinstall() {
  local -a status
  local console_rc=0 test_rc
  local console_log="${REPORT_DIR}/report/console.log"
  set +e
  ansible-playbook ./playbooks/ran/ibi-replacement-preinstall.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --extra-vars ibi_replacement_preinstall_phase=run \
    --extra-vars "ibi_hub_kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_seed_version=${SEED_VERSION}" \
    --extra-vars "ibi_seed_digest=${SEED_DIGEST}" \
    --extra-vars "ibi_git_revision=${GIT_REVISION}" \
    --extra-vars "ibi_git_repo=${ZTP_GIT_REPO}" \
    --extra-vars "ibi_release_version=${VERSION} ibi_seed_cluster=${SEED_SPOKE_CLUSTER}" \
    --extra-vars "ibi_preinstall_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_replacement_host=${IBI_REPLACEMENT_HOST}" \
    --extra-vars "ibi_replacement_mac=${IBI_REPLACEMENT_MAC}" \
    --extra-vars "ibi_replacement_ip=${IBI_REPLACEMENT_IP}" \
    --extra-vars "ibi_work_dir=${WORK_DIR} ibi_http_subdir=${HTTP_SUBDIR}" \
    --extra-vars "ibi_report_dir=${REPORT_DIR}" \
    --extra-vars '{"ibi_skip_tls_verify":true}' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/execution.log"
  status=("${PIPESTATUS[@]}")
  set -e

  # The playbook retains the launcher status and reports even when execution fails.
  if [[ ! -f "${console_log}" ]]; then console_log="${REPORT_DIR}/runner.log"; fi
  if [[ -f "${console_log}" ]]; then
    redact_bastion < "${console_log}" || console_rc=$?
  fi
  if [[ -s "${REPORT_DIR}/execution-exit-code" ]]; then
    test_rc=$(<"${REPORT_DIR}/execution-exit-code")
    [[ "${test_rc}" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( test_rc <= 255 )) || return 1
    if (( test_rc != 0 )); then return "${test_rc}"; fi
  fi
  (( status[0] == 0 )) || return "${status[0]}"
  (( status[1] == 0 )) || return "${status[1]}"
  (( status[2] == 0 )) || return "${status[2]}"
  if [[ ! -s "${REPORT_DIR}/execution-exit-code" ]]; then
    echo "Replacement preinstall did not retain its execution status." >&2
    return 1
  fi
  return "${console_rc}"
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" || "${IBI_REPLACEMENT_PREINSTALL_ENABLED:-false}" == false ]]; then
    echo "Skipping IBI replacement preinstall."
    return 0
  fi
  [[ "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == true ]]

  cd /eco-ci-cd
  restore_seed_inventory
  create_work_directories
  read_seed_inputs
  configure_ansible
  run_preinstall

  echo "IBI replacement preinstall execution and report collection completed."
}

main "$@"
