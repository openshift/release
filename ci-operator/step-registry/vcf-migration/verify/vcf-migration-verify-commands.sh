#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

readonly MIGRATION_NAMESPACE="openshift-vcf-migration"
readonly MIGRATION_NAME="cluster"

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

# The manual workflow never deploys the operator, so the migration resource
# (and its namespace) do not exist there; only enforce the Ready condition
# when the resource is present (operator-driven workflow).
if oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" >/dev/null 2>&1; then
  migration_ready="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o json | jq -r '
    .status.conditions[]? | select(.type == "Ready") | .status')"
  if [[ "${migration_ready}" != "True" ]]; then
    fail_with_details "migration resource Ready condition is ${migration_ready:-unset}"
  fi
else
  log "no VmwareCloudFoundationMigration resource; skipping the operator Ready check (manual migration)"
fi

# Verify node region/zone labels match target failure domain tags
if [[ -f "${SHARED_DIR}/vcf-migration-target-fds.json" ]]; then
  log "verifying node region/zone labels match target failure domains"

  # Build a list of valid target region/zone pairs
  target_zones="$(jq -r '[.[] | "\(.region)/\(.zone)"] | join(" ")' "${SHARED_DIR}/vcf-migration-target-fds.json")"

  # Check that every node matches at least one target failure domain
  mismatched_nodes="$(oc get nodes -o json | jq -r --arg zones "${target_zones}" '
    [.items[]
     | .metadata.labels["topology.kubernetes.io/region"] as $region
     | .metadata.labels["topology.kubernetes.io/zone"] as $zone
     | "\($region)/\($zone)" as $node_zone
     | select(($zones | split(" ") | contains([$node_zone])) | not)
     | .metadata.name] | join(",")')"

  if [[ -n "${mismatched_nodes}" ]]; then
    fail_with_details "nodes do not match target failure domains: ${mismatched_nodes}"
  fi

  # Log how many nodes are in each target zone
  while IFS= read -r fd; do
    region="$(jq -r '.region' <<< "${fd}")"
    zone="$(jq -r '.zone' <<< "${fd}")"

    nodes_in_zone="$(oc get nodes -o json | jq -r --arg region "${region}" --arg zone "${zone}" '
      [.items[]
       | select(.metadata.labels["topology.kubernetes.io/region"] == $region
                and .metadata.labels["topology.kubernetes.io/zone"] == $zone)
       | .metadata.name] | length')"

    log "verified ${nodes_in_zone} node(s) in region=${region} zone=${zone}"
  done < <(jq -c '.[]' "${SHARED_DIR}/vcf-migration-target-fds.json")
fi

# Verify MachineConfigPools are Updated and not Degraded
degraded_mcps="$(oc get machineconfigpools -o json | jq -r '
  [.items[]
   | select(
       any(.status.conditions[]?; .type == "Updated" and .status != "True")
       or any(.status.conditions[]?; .type == "Degraded" and .status != "False")
     )
   | .metadata.name] | join(",")')"
if [[ -n "${degraded_mcps}" ]]; then
  fail_with_details "MachineConfigPools are not converged: ${degraded_mcps}"
fi

log "verification succeeded; cluster now references only the target vCenter"
