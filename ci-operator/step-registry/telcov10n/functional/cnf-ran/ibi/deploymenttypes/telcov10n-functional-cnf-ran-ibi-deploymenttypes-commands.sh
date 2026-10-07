#!/bin/bash
set +x
set -euo pipefail
umask 077

TEMP_DIR=
SSH_READY=false

record_result() {
  printf '%s\n' "$1" > "${RESULT_FILE}"
}

finish() {
  local result=$1 copy_rc=0 save_rc=0
  trap - EXIT
  set +e

  if [[ "${SSH_READY}" == true ]]; then
    collect_reports
    copy_rc=$?
    if (( result == 0 )); then
      result=${copy_rc}
    fi
  fi

  record_result "${result}"
  save_rc=$?
  [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
  if (( save_rc != 0 )); then
    echo "Could not save the Deployment Types result." >&2
    exit "${save_rc}"
  fi

  echo "Deployment Types step status: ${result}; report-copy status: ${copy_rc}."
  echo "Subsequent stages may continue; the final result step will check this status."
  exit 0
}

validate_inputs() {
  : "${TARGET_CLUSTER_NAME:?TARGET_CLUSTER_NAME is required}"
  : "${TARGET_SPOKE_CLUSTER:?TARGET_SPOKE_CLUSTER is required}"
  TARGET_SPOKE_NAME=$(printf '%s' "${TARGET_SPOKE_CLUSTER}" | tr -d "[]'\" ")
  [[ "${TARGET_CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  [[ "${TARGET_SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
  HUB_CONFIG_DIR="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}"
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
  TEMP_DIR=$(mktemp -d /tmp/ibi-deploymenttypes.XXXXXX)
  WORK_DIR="/tmp/eco_gotests_ibi_deploymenttypes/${TEMP_DIR##*/}"
  # The preparation playbook deletes WORK_DIR, so keep the kubeconfig outside it.
  SPOKE_KUBECONFIG="/tmp/${TEMP_DIR##*/}-kubeconfig"
  REPORT_DIR="${ARTIFACT_DIR}/ibi-deploymenttypes"
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
  SSH_READY=true
}

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

fetch_target_kubeconfig() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "set -euo pipefail; umask 077
     oc --kubeconfig='${HUB_CONFIG_DIR}/auth/kubeconfig' -n '${TARGET_SPOKE_NAME}' \
       get secret '${TARGET_SPOKE_NAME}-admin-kubeconfig' \
       -o jsonpath='{.data.kubeconfig}' | base64 -d > '${SPOKE_KUBECONFIG}'
     test -s '${SPOKE_KUBECONFIG}'" \
    2>&1 | redact_bastion
}

prepare_launcher() {
  cd /eco-ci-cd
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook ./playbooks/deploy-run-eco-gotests.yaml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --private-key "${TEMP_DIR}/ssh-key" \
    --extra-vars "kubeconfig=${SPOKE_KUBECONFIG}" \
    --extra-vars "hub_clusterconfigs_path=${HUB_CONFIG_DIR}" \
    --extra-vars "eco_gotest_dir=${WORK_DIR}" \
    --extra-vars '{
      "features": "deploymenttypes",
      "labels": "!no-container",
      "eco_gotests_tag": "latest",
      "test_timeout": "3h",
      "eco_worker_label": "",
      "eco_cnf_core_net_switch_user": "",
      "eco_cnf_core_net_switch_pass": "",
      "eco_cnf_core_net_switch_ip": "",
      "eco_cnf_core_net_mlb_addr_list": "",
      "switch_lag_names": "",
      "report_test_case_tag": "test_id",
      "report_parameter_tag": "parameters",
      "report_tc_prefix": "ibi",
      "additional_test_env_variables": "-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true -e ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE=open-cluster-management -e ECO_TEST_TRACE=true -e ECO_VERBOSE_SCRIPT=true"
    }' \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/setup.log"
}

run_tests() {
  local -a status
  set +e
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" \
    "cd '${WORK_DIR}' &&
     sed -i 's/^podman run -it /podman run -i /' eco-gotests-run.sh &&
     exec ./eco-gotests-run.sh" \
    2>&1 | redact_bastion | tee "${REPORT_DIR}/runner.log"
  status=("${PIPESTATUS[@]}")
  set -e
  echo "Test execution status: ${status[0]}; log-write status: ${status[2]}."
  (( status[0] == 0 )) || return "${status[0]}"
  (( status[1] == 0 )) || return "${status[1]}"
  return "${status[2]}"
}

collect_reports() {
  scp -q -r "${SSH_OPTS[@]}" \
    "${BASTION_USER}@${BASTION_IP}:${WORK_DIR}/report" "${REPORT_DIR}/" \
    2>&1 | redact_bastion
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping IBI Deployment Types tests."
    return 0
  fi

  RESULT_FILE="${SHARED_DIR}/ibi-deploymenttypes-exit-code"
  record_result 1
  trap 'finish "$?"' EXIT

  validate_inputs
  restore_target_inventory
  create_work_directories
  configure_ssh
  fetch_target_kubeconfig
  prepare_launcher
  run_tests
}

main "$@"
