#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"
TRIDENT_NAMESPACE="trident"
cleanup_status=0

state_value() {
  local name="$1"
  local path="${SHARED_DIR}/${name}"

  if [[ -s "${path}" ]]; then
    cat "${path}"
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
  "$@" >"${output}" 2>&1 || true
}

gather_diagnostics() {
  local directory="${ARTIFACT_DIR}/fsxn-trident"
  local filesystem_id svm_id security_group
  mkdir -p "${directory}"

  filesystem_id="$(state_value fsxn-filesystem-id)"
  svm_id="$(state_value fsxn-svm-id)"
  security_group="$(state_value fsxn-security-group-id)"
  [[ -n "${filesystem_id}" ]] && gather "${directory}/fsxn-filesystem.json" aws fsx describe-file-systems --file-system-ids "${filesystem_id}"
  [[ -n "${svm_id}" ]] && gather "${directory}/fsxn-svm.json" aws fsx describe-storage-virtual-machines --storage-virtual-machine-ids "${svm_id}"
  [[ -n "${security_group}" ]] && gather "${directory}/fsxn-security-group.json" aws ec2 describe-security-groups --group-ids "${security_group}"

  if [[ ! -s "${KUBECONFIG}" ]]; then
    echo "Kubeconfig is unavailable; skipping cluster diagnostics" >"${directory}/cluster-unavailable"
    return
  fi

  gather "${directory}/trident-resources.yaml" oc get all,tridentorchestrator,tridentbackendconfig -n "${TRIDENT_NAMESPACE}" -o yaml
  gather "${directory}/trident-events.txt" oc get events -n "${TRIDENT_NAMESPACE}" --sort-by=.lastTimestamp
  gather "${directory}/storageclasses.yaml" oc get storageclass ci-netapp-iscsi ci-netapp-iscsi-luks ci-netapp-nvme ci-netapp-nvme-luks -o yaml
  gather "${directory}/pvcs.yaml" oc get pvc --all-namespaces -o yaml
  gather "${directory}/pvs.yaml" oc get pv -o yaml
  gather "${directory}/mcp-worker.yaml" oc get machineconfigpool worker -o yaml
  gather "${directory}/machineconfig.yaml" oc get machineconfig "$(state_value fsxn-machineconfig-name)" -o yaml
  gather "${directory}/trident-operator.log" oc logs deployment/trident-operator -n "${TRIDENT_NAMESPACE}" --all-containers=true

  local node
  while read -r node; do
    [[ -n "${node}" ]] || continue
    gather "${directory}/node-${node}-san-state.txt" timeout 90s oc debug "node/${node}" -- chroot /host sh -c 'multipath -ll; nvme list-subsys; iscsiadm -m session; systemctl status iscsid multipathd --no-pager'
  done < <(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

delete_test_pvcs() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local namespace name
  while read -r namespace name; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    oc delete pvc "${name}" --namespace "${namespace}" --ignore-not-found --wait=false || record_failure "could not delete PVC ${namespace}/${name}"
  done < <(oc get pvc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks") | "\(.metadata.namespace) \(.metadata.name)"' || true)

  wait_for 900 10 "FSxN test PVC cleanup" test_pvcs_removed || true
  oc delete namespace fsxn-trident-smoke --ignore-not-found --wait=true --timeout=15m || record_failure "could not delete smoke-test namespace"
}

test_pvcs_removed() {
  local remaining
  remaining="$(oc get pvc --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.spec.storageClassName == "ci-netapp-iscsi" or .spec.storageClassName == "ci-netapp-iscsi-luks" or .spec.storageClassName == "ci-netapp-nvme" or .spec.storageClassName == "ci-netapp-nvme-luks")] | length')"
  [[ "${remaining}" == "0" ]]
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

  delete_test_pvcs
  oc delete tridentbackendconfig ci-fsxn-iscsi ci-fsxn-iscsi-luks ci-fsxn-nvme ci-fsxn-nvme-luks --namespace "${TRIDENT_NAMESPACE}" --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete Trident backends"
  oc delete storageclass ci-netapp-iscsi ci-netapp-iscsi-luks ci-netapp-nvme ci-netapp-nvme-luks --ignore-not-found || record_failure "could not delete FSxN StorageClasses"

  if oc get tridentorchestrator trident >/dev/null 2>&1; then
    oc delete tridentorchestrator trident --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete TridentOrchestrator"
  fi

  install_helm || true
  if command -v helm >/dev/null; then
    helm uninstall trident --namespace "${TRIDENT_NAMESPACE}" || record_failure "could not uninstall Trident Helm release"
  fi

  clear_trident_finalizers
  oc delete namespace "${TRIDENT_NAMESPACE}" --ignore-not-found --wait=true --timeout=10m || record_failure "could not delete Trident namespace"
}

delete_svm() {
  local svm_id="$1"
  [[ -n "${svm_id}" ]] || return 0

  aws fsx delete-storage-virtual-machine --storage-virtual-machine-id "${svm_id}" >/dev/null 2>&1 || true
  wait_for 1200 20 "FSx SVM ${svm_id} deletion" bash -c "! aws fsx describe-storage-virtual-machines --storage-virtual-machine-ids '${svm_id}' >/dev/null 2>&1" || true
}

delete_filesystem() {
  local filesystem_id="$1"
  [[ -n "${filesystem_id}" ]] || return 0

  aws fsx delete-file-system --file-system-id "${filesystem_id}" >/dev/null 2>&1 || true
  wait_for 1800 30 "FSx filesystem ${filesystem_id} deletion" bash -c "! aws fsx describe-file-systems --file-system-ids '${filesystem_id}' >/dev/null 2>&1" || true
}

delete_security_group() {
  local security_group="$1"
  [[ -n "${security_group}" ]] || return 0

  local deadline=$(( $(date +%s) + 600 ))
  until aws ec2 delete-security-group --group-id "${security_group}" >/dev/null 2>&1; do
    if ! aws ec2 describe-security-groups --group-ids "${security_group}" >/dev/null 2>&1; then
      return
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
      record_failure "timed out deleting security group ${security_group}"
      return 0
    fi
    sleep 15
  done
}

cleanup_machineconfig() {
  [[ -s "${KUBECONFIG}" ]] || return 0

  local machineconfig
  machineconfig="$(state_value fsxn-machineconfig-name)"
  [[ -n "${machineconfig}" ]] || return 0
  oc delete machineconfig "${machineconfig}" --ignore-not-found || record_failure "could not delete ${machineconfig}"
  wait_for 3000 30 "worker MachineConfigPool cleanup" bash -c 'read -r updating updated degraded < <(oc get mcp worker -o jsonpath="{.status.conditions[?(@.type==\"Updating\")].status} {.status.conditions[?(@.type==\"Updated\")].status} {.status.conditions[?(@.type==\"Degraded\")].status}"); [[ "$updating" == False && "$updated" == True && "$degraded" == False ]]' || true
}

main() {
  local region filesystem_id svm_id security_group
  region="$(state_value fsxn-region)"
  filesystem_id="$(state_value fsxn-filesystem-id)"
  svm_id="$(state_value fsxn-svm-id)"
  security_group="$(state_value fsxn-security-group-id)"

  [[ -n "${region}" ]] && export AWS_DEFAULT_REGION="${region}"
  gather_diagnostics

  if [[ -n "${region}" ]]; then
    cleanup_trident
    delete_svm "${svm_id}"
    delete_filesystem "${filesystem_id}"
    delete_security_group "${security_group}"
  else
    cleanup_trident
    if [[ -n "${filesystem_id}" || -n "${svm_id}" || -n "${security_group}" ]]; then
      record_failure "FSxN cleanup state is incomplete: ${SHARED_DIR}/fsxn-region is missing"
    fi
  fi
  cleanup_machineconfig

  return "${cleanup_status}"
}

main "$@"
