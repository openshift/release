#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

readonly MIGRATION_NAMESPACE="openshift-vcf-migration"
readonly MIGRATION_NAME="vcf-migration-e2e"

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function fail_with_details() {
  local message="$1"
  log "${message}"
  oc get clusteroperators -o wide || true
  oc get nodes -o wide || true
  oc get infrastructure cluster -o name || true
  oc -n openshift-machine-api get machinesets,machines -o name || true
  oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' || true
  exit 1
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ ! -f "${SHARED_DIR}/vcf-migration-target-vcenter.txt" ]]; then
  fail_with_details "target vCenter artifact missing"
fi

target_vcenter="$(<"${SHARED_DIR}/vcf-migration-target-vcenter.txt")"

unhealthy_operators="$(oc get clusteroperators -o json | jq -r '
  [.items[]
   | select(
       any(.status.conditions[]?; .type == "Available" and .status != "True")
       or any(.status.conditions[]?; .type == "Progressing" and .status != "False")
       or any(.status.conditions[]?; .type == "Degraded" and .status != "False")
     )
   | .metadata.name] | join(",")')"
if [[ -n "${unhealthy_operators}" ]]; then
  fail_with_details "cluster operators are unhealthy: ${unhealthy_operators}"
fi

not_ready_nodes="$(oc get nodes -o json | jq -r '
  [.items[]
   | select(any(.status.conditions[]?; .type == "Ready" and .status != "True"))
   | .metadata.name] | join(",")')"
if [[ -n "${not_ready_nodes}" ]]; then
  fail_with_details "nodes are not Ready: ${not_ready_nodes}"
fi

infra_vcenters="$(oc get infrastructure cluster -o json | jq -r '.spec.platformSpec.vsphere.vcenters[]?.server')"
if [[ -z "${infra_vcenters}" ]]; then
  fail_with_details "infrastructure spec has no vCenter servers"
fi

unexpected_infra_vcenters="$(oc get infrastructure cluster -o json | jq -r --arg server "${target_vcenter}" '
  [.spec.platformSpec.vsphere.vcenters[]?.server | select(. != $server)] | join(",")')"
if [[ -n "${unexpected_infra_vcenters}" ]]; then
  fail_with_details "infrastructure still references non-target vCenters"
fi

unexpected_machine_servers="$(oc -n openshift-machine-api get machines -o json | jq -r --arg server "${target_vcenter}" '
  [.items[]
   | select(.metadata.deletionTimestamp == null)
   | select((.spec.providerSpec.value.workspace.server // "") != $server)
   | .metadata.name] | join(",")')"
if [[ -n "${unexpected_machine_servers}" ]]; then
  fail_with_details "machines still reference non-target vCenters: ${unexpected_machine_servers}"
fi

migration_ready="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o json | jq -r '
  .status.conditions[]? | select(.type == "Ready") | .status')"
if [[ "${migration_ready}" != "True" ]]; then
  fail_with_details "migration resource Ready condition is ${migration_ready:-unset}"
fi

log "verification succeeded; cluster now references only the target vCenter"
