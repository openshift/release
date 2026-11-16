#!/bin/bash
set +x
set -euo pipefail
umask 077

finish() {
  local rc=$?
  trap - EXIT
  rm -rf -- "${TEMP_DIR}" || rc=1
  if (( rc != 0 )); then
    printf '%s\n' "${rc}" > "${RESULT_FILE}" || rc=1
    echo "IBBF setup, execution, logging, or cleanup failed; stopping the workflow." >&2
  fi
  exit "${rc}"
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

prepare_inputs() {
  [[ "${IBI_REPLACEMENT_PREINSTALL_ENABLED}" == true ]]
  TARGET_SPOKE_NAME=$(printf '%s' "${TARGET_SPOKE_CLUSTER}" | tr -d "[]'\" ")
  [[ "${TARGET_CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${TARGET_SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  POLICY_REVISION=
  if [[ -n "${IBI_IBBF_REPLACEMENT_POLICY_PATH:-}" ]]; then
    POLICY_REVISION=$(<"${SHARED_DIR}/ibi-seed-git-revision")
  fi

  TEMP_DIR=$(mktemp -d /tmp/ibi-ibbf.XXXXXX)
  trap finish EXIT
  WORK_DIR="/tmp/eco_gotests_ibi_ibbf/${TEMP_DIR##*/}"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-ibbf"
  mkdir -p "${REPORT_DIR}"
  printf '%s\n' "${WORK_DIR}/report" > "${SHARED_DIR}/ibi-rp-ibbf-dir"
}

configure_ansible() {
  local bastion_identity
  install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="${TEMP_DIR}/ssh-key"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_RETRIES=3
  export ANSIBLE_TIMEOUT=600
  export ANSIBLE_REMOTE_TEMP=/tmp

  # Resolve YAML quoting and inventory precedence without logging private variables.
  if ! bastion_identity=$(
    exec 2>"${TEMP_DIR}/inventory.log" || exit 1
    ansible-inventory -i "${INVENTORY_PATH}/build-inventory.py" --host bastion |
      python3 -c '
import json, sys
host = json.load(sys.stdin)
values = [host.get(key) for key in ("ansible_host", "ansible_user")]
if any(not isinstance(value, str) or not value or any(c.isspace() for c in value) for value in values):
    sys.exit("Missing or invalid bastion connection identity.")
print(*values)
'
  ); then
    echo "Could not resolve target bastion inventory." >&2
    return 1
  fi
  read -r BASTION_IP BASTION_USER <<< "${bastion_identity}"
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//"${BASTION_USER}@${BASTION_IP}"/<bastion>}"
    line="${line//"${BASTION_IP}"/<bastion>}"
    printf '%s\n' "${line}"
  done
}

print_execution_logs() {
  local log
  for log in policy-fixture preflight setup runner policy-gate; do
    if [[ -f "${REPORT_DIR}/${log}.log" ]]; then
      echo "=== IBBF ${log} ==="
      cat -- "${REPORT_DIR}/${log}.log" || return "$?"
    fi
  done
}

run_ibbf() {
  local -a status
  local logs_rc=0 test_result
  set +e
  ansible-playbook ./playbooks/ran/ibi-ibbf.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --extra-vars "ibi_ibbf_inventory=${INVENTORY_PATH}/build-inventory.py" \
    --extra-vars "ibi_ibbf_hub_kubeconfig=/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_ibbf_spoke=${TARGET_SPOKE_NAME} ibi_ibbf_version=${VERSION}" \
    --extra-vars "ibi_ibbf_original_bmc=${IBI_IBBF_ORIGINAL_BMC_HOST}" \
    --extra-vars "ibi_ibbf_replacement_bmc=${IBI_IBBF_REPLACEMENT_BMC_HOST}" \
    --extra-vars "ibi_ibbf_target_ip=${IBI_IBBF_TARGET_IP}" \
    --extra-vars "ibi_ibbf_policy_path=${IBI_IBBF_REPLACEMENT_POLICY_PATH:-}" \
    --extra-vars "ibi_ibbf_policy_repo=${ZTP_GIT_REPO:-}" \
    --extra-vars "ibi_ibbf_policy_revision=${POLICY_REVISION}" \
    --extra-vars "ibi_ibbf_work_dir=${WORK_DIR} ibi_ibbf_report_dir=${REPORT_DIR}" \
    --extra-vars "ibi_ibbf_result_file=${RESULT_FILE}" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/playbook.log"
  status=("${PIPESTATUS[@]}")
  set -e

  print_execution_logs || logs_rc=$?
  (( status[0] == 0 )) || return "${status[0]}"
  (( status[1] == 0 )) || return "${status[1]}"
  (( status[2] == 0 )) || return "${status[2]}"
  (( logs_rc == 0 )) || return "${logs_rc}"
  test -s "${REPORT_DIR}/ibbf-status.json"
  test_result=$(<"${RESULT_FILE}")
  [[ "${test_result}" == 0 || "${test_result}" == 1 ]]
  cp -- "${REPORT_DIR}/ibbf-status.json" "${SHARED_DIR}/ibi-ibbf-status.json"
  echo "IBBF step completed; saved test result: ${test_result}. Final verification will enforce it after reporting."
}

main() {
  RESULT_FILE="${SHARED_DIR}/ibi-ibbf-exit-code"
  printf '1\n' > "${RESULT_FILE}"
  if [[ -f "${SHARED_DIR}/skip.txt" || "${IBI_IBBF_ENABLED:-false}" == false ]]; then
    printf '0\n' > "${RESULT_FILE}"
    echo "Skipping IBI IBBF tests."
    return 0
  fi
  [[ "${IBI_IBBF_ENABLED}" == true ]]

  cd /eco-ci-cd
  restore_target_inventory
  prepare_inputs
  configure_ansible
  run_ibbf
}

main "$@"
