#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Workaround for OCPBUGS-136128: installer IBM Cloud destroy does not paginate LB listing,
# so some cluster LBs are missed and block subnet/VPC deletion.
# Delete InfraID-matching LBs before deprovision and wait until they are gone.

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "No metadata.json found, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

infra_id=$(jq -r '.infraID // empty' "${SHARED_DIR}/metadata.json")
if [[ -z "${infra_id}" ]]; then
  echo "No infraID in metadata.json, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

resource_group=$(jq -r '.ibmcloud.resourceGroupName // empty' "${SHARED_DIR}/metadata.json")
if [[ -z "${resource_group}" ]]; then
  echo "No ibmcloud.resourceGroupName in metadata.json, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "LEASED_RESOURCE is empty, skipping IBM Cloud load balancer cleanup"
  exit 0
fi

# Boskos leases look like us-east--odf-ibmcloud-quota-slice-15; region is before "--".
region="${LEASED_RESOURCE%%--*}"

export IBMCLOUD_HOME=/output

# Disable CLI update checks so later ibmcloud calls do not stall on version lookups in CI.
ibmcloud config --check-version=false

echo "Logging into IBM Cloud region ${region} (LEASED_RESOURCE=${LEASED_RESOURCE}) for infraID ${infra_id} resource group ${resource_group}"
if ! ibmcloud login -r "${region}" --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -q; then
  echo "ERROR: ibmcloud login failed"
  exit 1
fi

# Find LBs in the cluster resource group whose names contain infraID.
# Prints one line per LB: id, name, status (tab-separated).
list_matching_lbs() {
  ibmcloud is load-balancers --resource-group-name "${resource_group}" --output json \
    | jq -r --arg infra "${infra_id}" '
        (if type == "array" then . else (.load_balancers // []) end)
        | map(select(.name != null and (.name | contains($infra))))
        | .[]
        | [.id, .name, (.provisioning_status // "unknown")]
        | @tsv
      '
}

# Best-effort delete; ignore failures in transient states so the wait loop can retry.
delete_matching_lbs() {
  local row lb_id lb_name lb_status
  for row in "$@"; do
    [[ -z "${row}" ]] && continue
    IFS=$'\t' read -r lb_id lb_name lb_status <<< "${row}"
    echo "Deleting load balancer ${lb_name} (${lb_id}, status=${lb_status})"
    ibmcloud is load-balancer-delete "${lb_id}" -f || true
  done
}

# Delete only accepts removal; wait until LBs are actually gone (up to ~35m).
wait_for_lbs_cleanup() {
  local out deadline=$((SECONDS + 2100))
  local -a rows
  echo "Waiting for load balancers matching infraID ${infra_id} to disappear"
  while (( SECONDS < deadline )); do
    if ! out=$(list_matching_lbs); then
      echo "WARNING: failed to re-list load balancers while waiting; will retry"
    elif [[ -z "${out}" ]]; then
      echo "All matching load balancers are gone"
      return 0
    else
      mapfile -t rows <<< "${out}"
      echo "Still waiting on ${#rows[@]} load balancer(s):"
      printf '  %s\n' "${rows[@]}"
      delete_matching_lbs "${rows[@]}"
    fi
    sleep 30
  done
  echo "WARNING: timed out waiting for load balancers to finish deleting; continuing to installer deprovision"
}

echo "Looking up load balancers matching infraID ${infra_id}"
if ! lb_output=$(list_matching_lbs); then
  echo "ERROR: failed to list load balancers"
  exit 1
fi
if [[ -z "${lb_output}" ]]; then
  echo "No load balancers found for infraID ${infra_id}"
  exit 0
fi
mapfile -t lb_rows <<< "${lb_output}"
echo "Found ${#lb_rows[@]} load balancer(s) for infraID ${infra_id}"
delete_matching_lbs "${lb_rows[@]}"
wait_for_lbs_cleanup
exit 0
