#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Workaround for OCPBUGS-136128: openshift-installer IBM Cloud destroy lists
# load balancers without pagination, so CCM/ingress kube-<infraID>-* LBs (and
# sometimes even leftover API LBs) can be missed and block subnet/VPC deletion.
# Delete all InfraID-matching LBs before installer deprovision, and wait until
# they are gone so subnet cleanup can proceed.

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "No metadata.json found, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

infra_id=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
if [[ -z "${infra_id}" || "${infra_id}" == "null" ]]; then
  echo "No infraID in metadata.json, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

# Boskos names look like us-east--odf-ibmcloud-quota-slice-15; region is the
# prefix before "--". If LEASED_RESOURCE is already a bare region, this is a no-op.
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "LEASED_RESOURCE is empty, skipping IBM Cloud load balancer cleanup"
  exit 0
fi
region="${LEASED_RESOURCE%%--*}"

export IBMCLOUD_CLI=ibmcloud
export IBMCLOUD_HOME=/output

if ! command -v "${IBMCLOUD_CLI}" >/dev/null 2>&1; then
  echo "ERROR: ${IBMCLOUD_CLI} not found in PATH; cannot clean up load balancers"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH; cannot clean up load balancers"
  exit 1
fi

"${IBMCLOUD_CLI}" config --check-version=false

echo "Logging into IBM Cloud region ${region} (from LEASED_RESOURCE=${LEASED_RESOURCE}) for infraID ${infra_id}"
if [[ -f "${SHARED_DIR}/ibmcloud-min-permission-api-key" ]]; then
  if ! "${IBMCLOUD_CLI}" login -r "${region}" --apikey @"${SHARED_DIR}/ibmcloud-min-permission-api-key" -q; then
    echo "ERROR: ibmcloud login failed"
    exit 1
  fi
else
  if ! "${IBMCLOUD_CLI}" login -r "${region}" --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -q; then
    echo "ERROR: ibmcloud login failed"
    exit 1
  fi
fi

list_matching_lbs() {
  "${IBMCLOUD_CLI}" is load-balancers --all-resource-groups --output json \
    | jq -r --arg infra "${infra_id}" '
        (if type == "array" then . else (.load_balancers // []) end)
        | map(select(.name != null and (.name | contains($infra))))
        | .[]
        | [.id, .name, (.provisioning_status // "unknown")]
        | @tsv
      '
}

delete_matching_lbs() {
  local row lb_id lb_name lb_status
  for row in "$@"; do
    [[ -z "${row}" ]] && continue
    IFS=$'\t' read -r lb_id lb_name lb_status <<< "${row}"
    echo "Deleting load balancer ${lb_name} (${lb_id}, status=${lb_status})"
    # Deletion can fail while the LB is in a transient state; keep trying from the wait loop.
    "${IBMCLOUD_CLI}" is load-balancer-delete "${lb_id}" -f || true
  done
}

echo "Looking up load balancers matching infraID ${infra_id}"
# Capture listing status before mapfile: process substitution does not propagate
# ibmcloud/jq failures to mapfile's exit status.
if ! lb_output=$(list_matching_lbs); then
  echo "ERROR: failed to list load balancers"
  exit 1
fi
lb_rows=()
if [[ -n "${lb_output}" ]]; then
  mapfile -t lb_rows <<< "${lb_output}"
fi

if [[ "${#lb_rows[@]}" -eq 0 ]]; then
  echo "No load balancers found for infraID ${infra_id}"
  exit 0
fi

echo "Found ${#lb_rows[@]} load balancer(s) for infraID ${infra_id}"
delete_matching_lbs "${lb_rows[@]}"

# IBM LB deletion can take up to ~30 minutes; allow a little polling overhead.
echo "Waiting for load balancers matching infraID ${infra_id} to disappear"
deadline=$((SECONDS + 2100)) # 35 minutes
while (( SECONDS < deadline )); do
  if ! remaining_output=$(list_matching_lbs); then
    echo "WARNING: failed to re-list load balancers while waiting; will retry"
    sleep 30
    continue
  fi
  remaining=()
  if [[ -n "${remaining_output}" ]]; then
    mapfile -t remaining <<< "${remaining_output}"
  fi
  if [[ "${#remaining[@]}" -eq 0 ]]; then
    echo "All matching load balancers are gone"
    exit 0
  fi
  echo "Still waiting on ${#remaining[@]} load balancer(s):"
  for row in "${remaining[@]}"; do
    echo "  ${row}"
  done
  # Retry deletes for LBs that may have been undeleteable on the previous attempt.
  delete_matching_lbs "${remaining[@]}"
  sleep 30
done

echo "WARNING: timed out waiting for load balancers to finish deleting; continuing to installer deprovision"
exit 0
