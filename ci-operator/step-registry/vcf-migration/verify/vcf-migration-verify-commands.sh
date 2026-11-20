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
  oc get machineconfigpools -o wide || true
  oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' || true
  exit 1
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ ! -f "${SHARED_DIR}/vcf-migration-target-vcenter.txt" ]]; then
  fail_with_details "target vCenter artifact missing"
fi

target_vcenter="$(<"${SHARED_DIR}/vcf-migration-target-vcenter.txt")"

# wait_for_cluster_operators_settled enforces the strict operator gate —
# Available=True, Progressing=False, Degraded=False for every
# clusteroperator; a fully settled cluster is the CI end-state — but
# re-evaluates it for up to 15 minutes before failing: a control plane
# replacement is followed by a static-pod revision roll (etcd,
# kube-apiserver, openshift-apiserver report Progressing while nodes move
# to the new revision) that settles on its own within minutes. Failed reads
# are retried within the same window; if the window expires while the latest
# read failed (and with any operator list it would have reported cleared,
# so it is never reported stale) the step fails loudly rather than passing
# on an unreadable state.
function wait_for_cluster_operators_settled() {
  local co_json unhealthy_operators co_read_ok=false
  local settle_deadline=$(( $(date +%s) + 900 ))

  while :; do
    if co_json="$(oc get clusteroperators -o json 2>/dev/null)"; then
      co_read_ok=true
      unhealthy_operators="$(jq -r '
        [.items[]
         | select(
             any(.status.conditions[]?; .type == "Available" and .status != "True")
             or any(.status.conditions[]?; .type == "Progressing" and .status != "False")
             or any(.status.conditions[]?; .type == "Degraded" and .status != "False")
           )
         | .metadata.name] | join(",")' <<< "${co_json}")"
      if [[ -z "${unhealthy_operators}" ]]; then
        return 0
      fi
      log "cluster operators still settling: ${unhealthy_operators}"
    else
      # A failed read invalidates the last operator list: without this the
      # deadline check below could fail on names up to 30s stale.
      unhealthy_operators=""
      co_read_ok=false
      log "failed to read cluster operators; retrying"
    fi
    if (( $(date +%s) >= settle_deadline )); then
      break
    fi
    sleep 30
  done

  if [[ -n "${unhealthy_operators:-}" ]]; then
    fail_with_details "cluster operators are unhealthy: ${unhealthy_operators}"
  fi
  if [[ "${co_read_ok}" != true ]]; then
    fail_with_details "failed to read cluster operators within the settle window"
  fi
}

wait_for_cluster_operators_settled

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
# when the resource is present (operator-driven workflow). The manual
# variant also has no CRD, so the not-found family — a missing resource or a
# missing resource type — is the expected absence; any other error (RBAC,
# apiserver, timeout) must fail the verification instead of silently
# skipping the Ready gate.
migration_get_status=0
migration_get_output="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" 2>&1)" \
  || migration_get_status=$?
if [[ "${migration_get_status}" -eq 0 ]]; then
  migration_ready="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o json | jq -r '
    .status.conditions[]? | select(.type == "Ready") | .status')"
  if [[ "${migration_ready}" != "True" ]]; then
    fail_with_details "migration resource Ready condition is ${migration_ready:-unset}"
  fi
elif grep -qiE "NotFound|not found|doesn't have a resource type|has no resource type" <<< "${migration_get_output}"; then
  log "no VmwareCloudFoundationMigration resource; skipping the operator Ready check (manual migration)"
else
  fail_with_details "failed to read the migration resource: ${migration_get_output}"
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

# wait_for_machine_config_pools_settled enforces the strict pool gate -
# Updated=True and Degraded=False for every MachineConfigPool - but
# re-evaluates it for up to 15 minutes before failing, in the same shape as
# wait_for_cluster_operators_settled: the control plane replacement re-rolls
# mcp/master (each new master must receive its machine config), so
# Updated=False can persist past the operator settle window. The manual
# migration step itself tolerates 30 minutes at its own MCP wait.
function wait_for_machine_config_pools_settled() {
  local mcp_json degraded_mcps mcp_read_ok=false
  local settle_deadline=$(( $(date +%s) + 900 ))

  while :; do
    if mcp_json="$(oc get machineconfigpools -o json 2>/dev/null)"; then
      mcp_read_ok=true
      degraded_mcps="$(jq -r '
  [.items[]
   | select(
       any(.status.conditions[]?; .type == "Updated" and .status != "True")
       or any(.status.conditions[]?; .type == "Degraded" and .status != "False")
     )
   | .metadata.name] | join(",")' <<< "${mcp_json}")"
      if [[ -z "${degraded_mcps}" ]]; then
        return 0
      fi
      log "machine config pools still settling: ${degraded_mcps}"
    else
      # A failed read invalidates the last pool list, as above.
      degraded_mcps=""
      mcp_read_ok=false
      log "failed to read machine config pools; retrying"
    fi
    if (( $(date +%s) >= settle_deadline )); then
      break
    fi
    sleep 30
  done

  if [[ -n "${degraded_mcps:-}" ]]; then
    fail_with_details "MachineConfigPools are not converged: ${degraded_mcps}"
  fi
  if [[ "${mcp_read_ok}" != true ]]; then
    fail_with_details "failed to read machine config pools within the settle window"
  fi
}

wait_for_machine_config_pools_settled

log "verification succeeded; cluster now references only the target vCenter"
