#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

state_value() {
  if [[ -s "${SHARED_DIR}/$1" ]]; then
    cat "${SHARED_DIR}/$1"
  fi
}

gather() {
  local output="$1"
  shift
  # Diagnostics must not prevent AWS cleanup. Keep command names and errors.
  (set -x; timeout 60s "$@") >"${directory}/${output}" 2>&1 || true
}

gather_diagnostics() {
  local directory="${ARTIFACT_DIR:-/tmp}/fsxn-trident" pod
  mkdir -p "${directory}"
  [[ -n "${filesystem_id}" ]] && gather fsxn-filesystem.json aws fsx describe-file-systems --file-system-ids "${filesystem_id}"
  [[ -n "${security_group}" ]] && gather fsxn-security-group.json aws ec2 describe-security-groups --group-ids "${security_group}"
  [[ -s "${KUBECONFIG}" ]] || return 0

  gather trident-resources.yaml oc get all,tridentorchestrator,tridentbackendconfig --namespace trident -o yaml
  gather trident-events.txt oc get events --namespace trident --sort-by=.lastTimestamp
  gather storageclasses.yaml oc get storageclass -o yaml
  gather pvcs.yaml oc get pvc --all-namespaces -o yaml
  gather pvs.yaml oc get pv -o yaml
  while read -r pod; do
    [[ -n "${pod}" ]] || continue
    gather "${pod##*/}.log" oc logs "${pod}" --namespace trident --all-containers=true --prefix=true
  done < <(oc get pods --namespace trident -o name --request-timeout=30s || true)
}

delete_aws_resources() {
  local filesystems volumes svms groups id volume svm pending=0
  # JSON output applies the query after aggregating all AWS pages. The tag is
  # saved before provisioning so cleanup also finds resources with a lost ID.
  filesystems="$(aws fsx describe-file-systems --query "FileSystems[?FileSystemId=='${filesystem_id}' || ('${resource_tag}'!='' && Tags[?Key=='Name' && Value=='${resource_tag}'])].FileSystemId" --output json)" || return 1
  for id in $(jq -r '.[]' <<<"${filesystems}"); do
    pending=1
    volumes="$(aws fsx describe-volumes --filters "Name=file-system-id,Values=${id}" --query 'Volumes[?OntapConfiguration.StorageVirtualMachineRoot==`false`].VolumeId' --output json)" || continue
    if [[ "$(jq length <<<"${volumes}")" != 0 ]]; then
      for volume in $(jq -r '.[]' <<<"${volumes}"); do
        # Do not leave chargeable final backups behind. Automatic backups are
        # disabled at creation; the SVM's root volume is removed with the SVM.
        aws fsx delete-volume --volume-id "${volume}" --ontap-configuration SkipFinalBackup=true >/dev/null || true
      done
      continue
    fi
    svms="$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=${id}" --query 'StorageVirtualMachines[].StorageVirtualMachineId' --output json)" || continue
    if [[ "$(jq length <<<"${svms}")" != 0 ]]; then
      for svm in $(jq -r '.[]' <<<"${svms}"); do
        aws fsx delete-storage-virtual-machine --storage-virtual-machine-id "${svm}" >/dev/null || true
      done
      continue
    fi
    aws fsx delete-file-system --file-system-id "${id}" >/dev/null || true
  done

  # The dedicated group cannot disappear until FSx has released its ENIs.
  # Match its ID or its unique cluster tag, never unrelated VPC security groups.
  [[ "${pending}" == 0 ]] || return 1
  groups="$(aws ec2 describe-security-groups --query "SecurityGroups[?GroupId=='${security_group}' || ('${resource_tag}'!='' && Tags[?Key=='Name' && Value=='${resource_tag}-sg'])].GroupId" --output json)" || return 1
  for id in $(jq -r '.[]' <<<"${groups}"); do
    pending=1
    aws ec2 delete-security-group --group-id "${id}" >/dev/null || true
  done
  # Only successful inventories proving absence can complete cleanup; API
  # failures and asynchronous deletes are retried, with errors left visible.
  [[ "${pending}" == 0 ]]
}

main() {
  local filesystem_id security_group resource_tag region deadline tool
  for tool in aws jq; do
    command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} is required" >&2; return 1; }
  done
  region="$(state_value fsxn-region)"
  filesystem_id="$(state_value fsxn-filesystem-id)"
  security_group="$(state_value fsxn-security-group-id)"
  resource_tag="$(state_value fsxn-resource-tag)"
  export AWS_DEFAULT_REGION="${region}"

  gather_diagnostics || true
  if [[ -z "${region}" ]]; then
    if [[ -n "${filesystem_id}${security_group}${resource_tag}" ]]; then
      echo "ERROR: FSxN resource state exists but fsxn-region is missing" >&2
      return 1
    fi
    return 0 # Provisioning never reached AWS resource creation.
  fi
  [[ -n "${filesystem_id}${security_group}${resource_tag}" ]] || return 0

  # No OCP objects are deleted: the disposable cluster is destroyed next.
  set -x
  deadline=$(( $(date +%s) + 4200 ))
  until delete_aws_resources; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      echo "ERROR: timed out deleting FSxN AWS resources" >&2
      return 1
    fi
    sleep 30
  done
}

main "$@"
