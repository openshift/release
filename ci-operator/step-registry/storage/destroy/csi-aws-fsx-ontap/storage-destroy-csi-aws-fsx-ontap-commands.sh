#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

TRIDENT_NAMESPACE="trident"
cleanup_status=0
: "${HELM_VERSION:=3.17.3}"

state_value() {
  if [[ -s "${SHARED_DIR}/$1" ]]; then
    cat "${SHARED_DIR}/$1"
  fi
}

record_failure() {
  echo "ERROR: $*" >&2
  cleanup_status=1
}

wait_for() {
  local timeout="$1" interval="$2" description="$3"
  shift 3
  local deadline=$(( $(date +%s) + timeout ))

  until "$@" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      record_failure "timed out waiting for ${description}"
      return 1
    fi
    sleep "${interval}"
  done
}

install_helm() {
  if command -v helm >/dev/null; then
    return
  fi

  local archive="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  if ! curl --fail --location --silent --show-error "https://get.helm.sh/${archive}" -o "/tmp/${archive}" ||
    ! curl --fail --location --silent --show-error "https://get.helm.sh/${archive}.sha256sum" -o "/tmp/${archive}.sha256sum" ||
    ! (cd /tmp && sha256sum --check --status "${archive}.sha256sum") ||
    ! tar -xzf "/tmp/${archive}" -C /tmp; then
    record_failure "could not install Helm for Trident cleanup"
    return 1
  fi
  install -m 0755 /tmp/linux-amd64/helm /tmp/helm
  export PATH="/tmp:${PATH}"
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

delete_test_pvcs() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local namespace name target_pvcs
  target_pvcs="$(oc get pvc --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") | "\(.metadata.namespace)/\(.metadata.name)"]' || true)"
  [[ -n "${target_pvcs}" ]] || target_pvcs='[]'

  # PVC protection prevents deletion until every pod that mounts the claim is gone.
  while read -r namespace name; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    oc delete pod "${name}" --namespace "${namespace}" --ignore-not-found --wait=false || record_failure "could not delete pod ${namespace}/${name} using an FSxN test PVC"
  done < <(oc get pod --all-namespaces -o json 2>/dev/null | jq -r --argjson target_pvcs "${target_pvcs}" '.items[] | . as $pod | select(any(.spec.volumes[]?; .persistentVolumeClaim? as $claim | $claim != null and ($target_pvcs | index("\($pod.metadata.namespace)/\($claim.claimName)")))) | "\(.metadata.namespace) \(.metadata.name)"' || true)

  while read -r namespace name; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    oc delete pvc "${name}" --namespace "${namespace}" --ignore-not-found --wait=false || record_failure "could not delete PVC ${namespace}/${name}"
  done < <(oc get pvc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") | "\(.metadata.namespace) \(.metadata.name)"' || true)

  if ! wait_for_test_pvcs; then
    clear_test_volume_finalizers
    wait_for 120 10 "forced FSxN test PVC cleanup" test_pvcs_removed || true
  fi
  oc delete namespace fsxn-trident-smoke --ignore-not-found --wait=true --timeout=15m || record_failure "could not delete smoke-test namespace"
}

test_pvcs_removed() {
  local remaining
  remaining="$(oc get pvc --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks")] | length')"
  [[ "${remaining}" == "0" ]]
}

wait_for_test_pvcs() {
  local deadline=$(( $(date +%s) + 900 ))

  until test_pvcs_removed; do
    [[ $(date +%s) -lt ${deadline} ]] || return 1
    sleep 10
  done
}

clear_test_volume_finalizers() {
  local namespace name

  # Trident may be unavailable after a failed teardown. These claims and
  # volumes belong solely to the CI StorageClasses, so unblock their deletion.
  while read -r namespace name; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    oc patch pvc "${name}" --namespace "${namespace}" --type=merge -p '{"metadata":{"finalizers":[]}}' || record_failure "could not clear finalizers on PVC ${namespace}/${name}"
  done < <(oc get pvc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select((.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") and .metadata.deletionTimestamp != null) | "\(.metadata.namespace) \(.metadata.name)"' || true)

  while read -r name; do
    [[ -n "${name}" ]] || continue
    oc delete pv "${name}" --ignore-not-found --wait=false || record_failure "could not delete PV ${name}"
  done < <(oc get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") | .metadata.name' || true)

  while read -r name; do
    [[ -n "${name}" ]] || continue
    oc patch pv "${name}" --type=merge -p '{"metadata":{"finalizers":[]}}' || record_failure "could not clear finalizers on PV ${name}"
  done < <(oc get pv -o json 2>/dev/null | jq -r '.items[] | select((.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") and .metadata.deletionTimestamp != null) | .metadata.name' || true)
}

clear_trident_finalizers() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local resource namespace name
  while read -r resource; do
    [[ -n "${resource}" ]] || continue
    while read -r namespace name; do
      [[ -n "${name}" ]] || continue
      if [[ -n "${namespace}" ]]; then
        oc patch "${resource}" "${name}" --namespace "${namespace}" --type=merge -p '{"metadata":{"finalizers":[]}}' || record_failure "could not clear finalizers on ${resource}/${name}"
      else
        oc patch "${resource}" "${name}" --type=merge -p '{"metadata":{"finalizers":[]}}' || record_failure "could not clear finalizers on ${resource}/${name}"
      fi
    done < <(oc get "${resource}" --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done < <(oc get crd -o name 2>/dev/null | awk -F/ '/trident\.netapp\.io/ {print $2}' || true)
}

cleanup_trident() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local backend_crd
  delete_test_pvcs
  # Provisioning may have failed before the Trident API was installed.
  if backend_crd="$(oc get crd tridentbackendconfigs.trident.netapp.io --ignore-not-found -o name)"; then
    if [[ -n "${backend_crd}" ]]; then
      oc delete tridentbackendconfig ci-fsxn-iscsi ci-fsxn-iscsi-luks ci-fsxn-nvme ci-fsxn-nvme-luks --namespace "${TRIDENT_NAMESPACE}" --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete Trident backends"
    fi
  else
    record_failure "could not discover Trident backend API"
  fi
  oc delete storageclass ci-netapp-iscsi ci-netapp-iscsi-luks ci-netapp-nvme ci-netapp-nvme-luks --ignore-not-found || record_failure "could not delete FSxN StorageClasses"

  if oc get tridentorchestrator trident >/dev/null 2>&1; then
    oc delete tridentorchestrator trident --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete TridentOrchestrator"
  fi

  install_helm || true
  if command -v helm >/dev/null; then
    helm uninstall trident --namespace "${TRIDENT_NAMESPACE}" --ignore-not-found || record_failure "could not uninstall Trident Helm release"
  fi

  clear_trident_finalizers
  oc delete namespace "${TRIDENT_NAMESPACE}" --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete Trident namespace"
}

worker_machineconfig_removed() {
  oc get mcp worker -o json | jq -e --arg name "$1" '
    (.spec.configuration.name == .status.configuration.name) and
    all(.spec.configuration.source[]?, .status.configuration.source[]?; .name != $name) and
    any(.status.conditions[]; .type == "Updating" and .status == "False") and
    any(.status.conditions[]; .type == "Updated" and .status == "True") and
    any(.status.conditions[]; .type == "Degraded" and .status == "False")'
}

cleanup_machineconfig() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local machineconfig
  machineconfig="$(state_value fsxn-machineconfig-name)"
  [[ -n "${machineconfig}" ]] || return 0
  oc delete machineconfig "${machineconfig}" --ignore-not-found || record_failure "could not delete ${machineconfig}"
  # Healthy conditions alone may still describe the old configuration before
  # the controller notices the deletion. Wait for desired AND applied sources.
  wait_for 3000 30 "worker MachineConfigPool cleanup" worker_machineconfig_removed "${machineconfig}" || true
}

delete_resource() {
  local error
  if error="$("$@" 2>&1 >/dev/null)"; then
    return 0
  fi

  # A concurrent deletion (for example by Trident) is harmless. Only a
  # successful inventory proving absence can complete the overall cleanup.
  case "${error}" in
    *'(VolumeNotFound)'*|*'(StorageVirtualMachineNotFound)'*|*'(FileSystemNotFound)'*|*'(InvalidGroup.NotFound)'*)
      return 0 ;;
    *'(BadRequest)'*|*'(ResourceInUse)'*|*'(DependencyViolation)'*|*'(Throttling)'*|*'(ThrottlingException)'*|*'(TooManyRequestsException)'*|*'(RequestLimitExceeded)'*|*'(ServiceUnavailable)'*|*'(InternalServerError)'*|*'(InternalServerException)'*|*'Could not connect to the endpoint URL'*|*'Connect timeout'*|*'Read timeout'*|*'Connection was closed'*)
      # FSx can reject deletion while provisioning or another operation is
      # completing. Retry under the global deadline, keeping the same token.
      echo "Retrying $1 $2 $3: ${error}" >&2
      return 0 ;;
    *)
      echo "ERROR: $1 $2 $3 failed: ${error}" >&2
      return 1 ;;
  esac
}

delete_aws_resources() {
  local filesystems volumes svms groups id volume svm lifecycle pending=0
  # JSON output applies the query after aggregating all AWS pages. The tag is
  # saved before provisioning so cleanup also finds resources with a lost ID.
  filesystems="$(aws fsx describe-file-systems --query "FileSystems[?FileSystemId=='${filesystem_id}' || ('${resource_tag}'!='' && Tags[?Key=='Name' && Value=='${resource_tag}'])].[FileSystemId,Lifecycle]" --output json)" || return 1
  while read -r id lifecycle; do
    pending=1
    [[ "${lifecycle}" == DELETING ]] && continue
    volumes="$(aws fsx describe-volumes --filters "Name=file-system-id,Values=${id}" --query 'Volumes[?OntapConfiguration.StorageVirtualMachineRoot==`false`].[VolumeId,Lifecycle]' --output json)" || continue
    if [[ "$(jq length <<<"${volumes}")" != 0 ]]; then
      while read -r volume lifecycle; do
        [[ "${lifecycle}" == DELETING ]] && continue
        # Do not leave chargeable final backups behind. Automatic backups are
        # disabled at creation; the SVM's root volume is removed with the SVM.
        # Resource IDs make tokens stable across retries and step restarts,
        # unlike the fresh token generated by each AWS CLI invocation.
        delete_resource aws fsx delete-volume --volume-id "${volume}" --ontap-configuration "SkipFinalBackup=true" --client-request-token "delete-${volume}" || return 2
      done < <(jq -r '.[] | @tsv' <<<"${volumes}")
      continue
    fi
    svms="$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=${id}" --query 'StorageVirtualMachines[].[StorageVirtualMachineId,Lifecycle]' --output json)" || continue
    if [[ "$(jq length <<<"${svms}")" != 0 ]]; then
      while read -r svm lifecycle; do
        [[ "${lifecycle}" == DELETING ]] && continue
        delete_resource aws fsx delete-storage-virtual-machine --storage-virtual-machine-id "${svm}" --client-request-token "delete-${svm}" || return 2
      done < <(jq -r '.[] | @tsv' <<<"${svms}")
      continue
    fi
    # ONTAP filesystem and SVM deletion do not accept --ontap-configuration.
    delete_resource aws fsx delete-file-system --file-system-id "${id}" --client-request-token "delete-${id}" || return 2
  done < <(jq -r '.[] | @tsv' <<<"${filesystems}")

  # The dedicated group cannot disappear until FSx has released its ENIs.
  # Match its ID or its unique cluster tag, never unrelated VPC security groups.
  [[ "${pending}" == 0 ]] || return 1
  groups="$(aws ec2 describe-security-groups --query "SecurityGroups[?GroupId=='${security_group}' || ('${resource_tag}'!='' && Tags[?Key=='Name' && Value=='${resource_tag}-sg'])].GroupId" --output json)" || return 1
  for id in $(jq -r '.[]' <<<"${groups}"); do
    pending=1
    delete_resource aws ec2 delete-security-group --group-id "${id}" || return 2
  done
  # Only successful inventories proving absence can complete cleanup; API
  # failures and asynchronous deletes are retried, with errors left visible.
  [[ "${pending}" == 0 ]]
}

main() {
  local filesystem_id security_group resource_tag region deadline tool status
  for tool in aws jq; do
    command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} is required" >&2; return 1; }
  done
  region="$(state_value fsxn-region)"
  filesystem_id="$(state_value fsxn-filesystem-id)"
  security_group="$(state_value fsxn-security-group-id)"
  resource_tag="$(state_value fsxn-resource-tag)"
  export AWS_DEFAULT_REGION="${region}"

  gather_diagnostics || true
  # Keep Trident available until the test PVCs have been removed so it can
  # unpublish and delete their backing volumes before AWS teardown starts.
  cleanup_trident
  if [[ -z "${region}" ]]; then
    if [[ -n "${filesystem_id}${security_group}${resource_tag}" ]]; then
      record_failure "FSxN resource state exists but fsxn-region is missing"
    fi
  elif [[ -n "${filesystem_id}${security_group}${resource_tag}" ]]; then
    deadline=$(( $(date +%s) + 4200 ))
    until delete_aws_resources; do
      status=$?
      if [[ ${status} == 2 ]]; then
        record_failure "AWS cleanup stopped after a non-retryable deletion error"
        break
      fi
      if [[ $(date +%s) -ge ${deadline} ]]; then
        record_failure "timed out deleting FSxN AWS resources"
        break
      fi
      sleep 30
    done
  fi
  # Attempt worker restoration even if AWS cleanup failed.
  cleanup_machineconfig
  return "${cleanup_status}"
}

main "$@"
