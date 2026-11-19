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

prepare_inventory() {
  local side host suffix index
  mkdir -p "${TEMP_DIR}/inventory/host_vars"
  printf '%s\n' '{"all":{"hosts":{"bastion":{},"ibi_report_seed":{}}}}' > "${TEMP_DIR}/inventory/hosts.yml"
  for side in seed target; do
    if [[ "$side" == seed ]]; then
      [[ -f "${SHARED_DIR}/ibi-rp-seedgen-dir" || -f "${SHARED_DIR}/ibi-rp-preinstall_replacement-dir" ]] || continue
      host=ibi_report_seed
    else
      host=bastion
    fi
    mkdir -p "${TEMP_DIR}/inventory/host_vars/${host}"
    # Ansible loads these files in order: all < bastions < bastion.
    index=0
    for suffix in all bastions bastion; do
      cp "${SHARED_DIR}/${side}-${suffix}" "${TEMP_DIR}/inventory/host_vars/${host}/${index}-${suffix}.yml"
      index=$((index + 1))
    done
  done
}

configure_ansible() {
  install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="${TEMP_DIR}/ssh-key"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_REMOTE_TEMP=/tmp
  export ANSIBLE_TIMEOUT=600
  # Upload requests must never be resubmitted after a transport failure.
  export ANSIBLE_SSH_RETRIES=0
}

run_report() {
  : "${TARGET_CLUSTER_NAME:?TARGET_CLUSTER_NAME is required for the shared uploader}"
  jq -n --arg shared "$SHARED_DIR" --arg output "${ARTIFACT_DIR}/reportportal" \
    --arg work "${TEMP_DIR}/reports" --arg version "$VERSION" \
    --arg kubeconfig "/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig" \
    --arg launch "$IBI_REPORTPORTAL_LAUNCH_NAME" --arg build "${BUILD_ID:-unknown}" \
    '{ibi_report_shared_dir:$shared, ibi_report_output_dir:$output,
      ibi_report_work_dir:$work, ibi_report_version:$version,
      ibi_report_launch_name:$launch, ibi_report_build_id:$build,
      ibi_report_hub_kubeconfig:$kubeconfig}' > "${TEMP_DIR}/inputs.json"

  echo "Collecting IBI stage reports and uploading to Report Portal."
  # Inventory and upload diagnostics may contain credentials; publish only
  # the playbook's reporting-status.json and launch link.
  local status=0
  ansible-playbook ./playbooks/ran/ibi-report.yml \
    -i "${TEMP_DIR}/inventory/hosts.yml" -e "@${TEMP_DIR}/inputs.json" \
    > "${TEMP_DIR}/reporting.log" 2>&1 || status=$?
  printf 'IBI reporting status: %s. See reportportal artifacts for details.\n' "$status"
  if [[ -s "${ARTIFACT_DIR}/reportportal/reportportal-url.txt" ]]; then
    printf 'Report Portal: %s\n' "$(<"${ARTIFACT_DIR}/reportportal/reportportal-url.txt")"
  fi
  return "$status"
}

main() {
  local lane registered=false
  if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping IBI Report Portal upload."
    return 0
  fi
  mkdir -p "${ARTIFACT_DIR}/reportportal"
  rm -f -- "${SHARED_DIR}/ibi-reportportal-url" \
    "${ARTIFACT_DIR}/reportportal/reportportal-url.txt"
  for lane in seedgen preinstall ibi preinstall_replacement ibbf; do
    if [[ -f "${SHARED_DIR}/ibi-rp-${lane}-dir" ]]; then registered=true; fi
  done
  if ! "$registered"; then
    printf '%s\n' '{"stages":{},"upload":"skipped: no test stage registered a report directory"}' \
      > "${ARTIFACT_DIR}/reportportal/reporting-status.json"
    echo "No IBI stage reports registered; skipping upload."
    return 0
  fi
  printf '%s\n' '{"phase":"controller preparation","upload":"not attempted"}' \
    > "${ARTIFACT_DIR}/reportportal/reporting-status.json"
  cd /eco-ci-cd
  TEMP_DIR=$(mktemp -d /tmp/ibi-reportportal.XXXXXX)
  trap cleanup EXIT
  prepare_inventory
  configure_ansible
  run_report
}

main "$@"
