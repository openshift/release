#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
export AZURE_CREDENTIALS_FILE=/etc/hypershift-ci-jobs-self-managed-azure/credentials.json

# Returns 0 if the resource group name matches CI naming conventions.
# Management cluster RGs: {10-hex}-mgmt-{10-hex}-mgmt (with optional vnet-/nsg- infix)
# Guest cluster RGs: {20-hex}-{5..20-hex} (with optional vnet-/nsg- infix)
is_ci_rg() {
  local name="$1"
  [[ "$name" =~ ^[0-9a-f]{10}-mgmt-((vnet|nsg)-)?[0-9a-f]{10}-mgmt$ ]] && return 0
  [[ "$name" =~ ^[0-9a-f]{20}-((vnet|nsg)-)?[0-9a-f]{5,20}$ ]] && return 0
  return 1
}

# Returns 0 if a DNS record name contains a CI cluster hash (10+ hex chars).
# CI cluster names are derived from SHA256(PROW_JOB_ID), so they always
# contain long hex sequences. Non-CI records (root cluster, personal
# clusters) do not.
is_ci_dns_record() {
  local name="$1"
  [[ "$name" =~ [0-9a-f]{10} ]] && return 0
  return 1
}

DRY_RUN="${DRY_RUN:-false}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "*** DRY RUN MODE — no resources will be deleted ***"
fi

phase1_rc=0
phase2_rc=0
phase3_rc=0

##############################################################################
# Phase 1: HostedCluster Pruner
#
# Connects to the Azure root cluster and destroys HostedClusters in the
# "clusters" namespace that are older than CLUSTER_TTL.
##############################################################################
PHASE1_TIMEOUT="${PHASE1_TIMEOUT:-14400}"

phase1_hc_pruner() {
  echo "=== Phase 1: HostedCluster Pruner (budget: ${PHASE1_TIMEOUT}s) ==="
  local had_failure=0

  local ttl_seconds=$(( $(date -u +%s) - $(date -u --date="${CLUSTER_TTL}" +%s) ))
  hostedclusters="$(oc get hostedcluster -n clusters -o json | jq -r \
    --argjson timestamp "${ttl_seconds}" \
    '.items[] | select(.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp) | .metadata.name')"

  if [[ -z "${hostedclusters}" ]]; then
    echo "No stale HostedClusters found."
    return 0
  fi

  local phase1_start
  phase1_start="$(date -u +%s)"

  for hc in ${hostedclusters}; do
    local elapsed=$(( $(date -u +%s) - phase1_start ))
    if [[ ${elapsed} -ge ${PHASE1_TIMEOUT} ]]; then
      echo "Phase 1: time budget exhausted after ${elapsed}s, skipping remaining HostedClusters."
      had_failure=$((had_failure+1))
      break
    fi
    local remaining=$(( PHASE1_TIMEOUT - elapsed ))

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] Would destroy stale HostedCluster: ${hc}"
    else
      echo "Destroying stale HostedCluster: ${hc} (${remaining}s remaining in phase budget)"
      timeout --signal=SIGTERM "${remaining}s" /hypershift/bin/hypershift destroy cluster azure \
        --azure-creds="${AZURE_CREDENTIALS_FILE}" \
        --name="${hc}" \
        --namespace=clusters \
        --dns-zone-rg-name=os4-common \
        --cluster-grace-period 40m || had_failure=$((had_failure+1))
    fi
  done

  if [[ ${had_failure} -ne 0 ]]; then
    echo "Phase 1: ${had_failure} HostedCluster destroy(s) failed."
    return 1
  fi
  echo "Phase 1: complete."
}

##############################################################################
# Phase 2: Orphaned Resource Group Sweep
#
# Authenticates to Azure, lists all resource groups, and deletes CI-created
# ones older than CLUSTER_TTL.
##############################################################################
phase2_rg_sweep() {
  echo "=== Phase 2: Orphaned Resource Group Sweep ==="

  # Disable tracing due to credential handling
  [[ $- == *x* ]] && local was_tracing=true || local was_tracing=false
  set +x
  az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_CREDENTIALS_FILE}")" \
    -p "$(jq -r .clientSecret "${AZURE_CREDENTIALS_FILE}")" \
    --tenant "$(jq -r .tenantId "${AZURE_CREDENTIALS_FILE}")" \
    --output none
  $was_tracing && set -x

  local subscription_id
  subscription_id="$(jq -r .subscriptionId "${AZURE_CREDENTIALS_FILE}")"
  az account set --subscription "${subscription_id}"

  local rg_age_cutoff
  rg_age_cutoff="$(date -u --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Deleting CI resource groups created before ${rg_age_cutoff} ..."

  # Use ARM REST API with $expand=createdTime since az group list does not
  # return createdTime by default. Paginate via nextLink.
  local rg_json="[]"
  local next_url="/subscriptions/${subscription_id}/resourcegroups?api-version=2021-04-01&\$expand=createdTime"
  while [[ -n "${next_url}" ]]; do
    local page
    page="$(az rest --method get --url "${next_url}")"
    rg_json="$(jq -s '.[0] + [.[1].value[] | {name: .name, created: .createdTime, state: .properties.provisioningState}]' \
      <(echo "${rg_json}") <(echo "${page}"))"
    next_url="$(echo "${page}" | jq -r '.nextLink // empty')"
  done

  local had_failure=0
  local deleted=0

  while IFS=$'\t' read -r rg_name rg_created rg_state; do
    [[ -z "${rg_name}" ]] && continue
    [[ "${rg_name}" == "os4-common" ]] && continue
    [[ "${rg_state}" == "Deleting" ]] && continue

    if ! is_ci_rg "${rg_name}"; then
      continue
    fi

    if [[ "${rg_created}" > "${rg_age_cutoff}" ]]; then
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] Would delete resource group: ${rg_name} (created ${rg_created})"
    else
      echo "Deleting resource group: ${rg_name} (created ${rg_created})"
      az group delete --name "${rg_name}" --yes --no-wait || had_failure=$((had_failure+1))
    fi
    deleted=$((deleted+1))
  done < <(echo "${rg_json}" | jq -r '.[] | [.name, .created, .state] | @tsv')

  echo "Phase 2: initiated deletion of ${deleted} resource group(s)."
  if [[ ${had_failure} -ne 0 ]]; then
    echo "Phase 2: ${had_failure} deletion(s) failed."
    return 1
  fi
  echo "Phase 2: complete."
}

##############################################################################
# Phase 3: Orphaned DNS Record Sweep
#
# Builds a set of active infra-ID prefixes from surviving resource groups,
# then deletes DNS records in the CI zones that don't match any active prefix.
##############################################################################
phase3_dns_sweep() {
  echo "=== Phase 3: Orphaned DNS Record Sweep ==="
  local had_failure=0

  # Build set of active infra-ID prefixes from surviving CI resource groups.
  # Extract the base infra-ID (first component before any vnet-/nsg- infix).
  local -A active_prefixes
  while IFS=$'\t' read -r rg_name rg_state; do
    [[ -z "${rg_name}" ]] && continue
    [[ "${rg_state}" == "Deleting" ]] && continue
    if is_ci_rg "${rg_name}"; then
      # Strip vnet-/nsg- infix and trailing infra-id suffix to get the cluster name prefix.
      # Management: {10hex}-mgmt-[vnet-|nsg-]{10hex}-mgmt → {10hex}-mgmt
      # Guest:      {20hex}-[vnet-|nsg-]{5-20hex}         → {20hex}
      local prefix="${rg_name}"
      prefix="${prefix//-vnet-/-}"
      prefix="${prefix//-nsg-/-}"
      prefix="${prefix%%-[0-9a-f]*}"
      # For mgmt clusters the prefix is "{10hex}-mgmt", re-add -mgmt if stripped
      if [[ "${rg_name}" == *-mgmt-* ]]; then
        prefix="${rg_name%%-mgmt-*}-mgmt"
      else
        # Guest cluster: prefix is the first 20 hex chars
        prefix="${rg_name:0:20}"
      fi
      active_prefixes["${prefix}"]=1
    fi
  done < <(az group list --query "[].{name:name, state:properties.provisioningState}" -o tsv)

  # Snapshot associative array keys into a regular array for nounset-safe iteration
  set +o nounset
  local prefix_count=${#active_prefixes[@]}
  local prefix_keys=("${!active_prefixes[@]}")
  set -o nounset
  echo "Found ${prefix_count} active CI cluster prefix(es)."

  local dns_zones=(
    "hcp-sm-azure.azure.devcluster.openshift.com"
    "sm.hcp-sm-azure.azure.devcluster.openshift.com"
  )
  local dns_rg="os4-common"

  for zone in "${dns_zones[@]}"; do
    echo "Sweeping DNS zone: ${zone}"
    local deleted_in_zone=0

    while IFS=$'\t' read -r record_name record_type; do
      [[ -z "${record_name}" ]] && continue
      # Skip zone apex SOA and NS records
      [[ "${record_name}" == "@" ]] && continue
      [[ "${record_type}" == "SOA" || "${record_type}" == "NS" ]] && continue

      # Only consider records that look like CI-created records
      if ! is_ci_dns_record "${record_name}"; then
        continue
      fi

      # Check if this record matches any active prefix
      local is_active=false
      for prefix in "${prefix_keys[@]}"; do
        if [[ "${record_name}" == *"${prefix}"* ]]; then
          is_active=true
          break
        fi
      done

      if [[ "${is_active}" == "false" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "[dry-run] Would delete orphaned DNS record: ${record_name} (${record_type}) in ${zone}"
        else
          echo "Deleting orphaned DNS record: ${record_name} (${record_type}) in ${zone}"
          az network dns record-set "${record_type,,}" delete \
            --resource-group "${dns_rg}" \
            --zone-name "${zone}" \
            --name "${record_name}" \
            --yes || had_failure=$((had_failure+1))
        fi
        deleted_in_zone=$((deleted_in_zone+1))
      fi
    done < <(az network dns record-set list \
      --resource-group "${dns_rg}" \
      --zone-name "${zone}" \
      --query "[].{name:name, type:type}" -o tsv | sed 's|Microsoft.Network/dnszones/||')

    echo "Deleted ${deleted_in_zone} orphaned record(s) from ${zone}."
  done

  if [[ ${had_failure} -ne 0 ]]; then
    echo "Phase 3: ${had_failure} DNS deletion(s) failed."
    return 1
  fi
  echo "Phase 3: complete."
}

##############################################################################
# Main
##############################################################################
phase1_hc_pruner || phase1_rc=$?
phase2_rg_sweep || phase2_rc=$?
phase3_dns_sweep || phase3_rc=$?

if [[ ${phase1_rc} -ne 0 || ${phase2_rc} -ne 0 || ${phase3_rc} -ne 0 ]]; then
  echo "Failures detected: phase1=${phase1_rc} phase2=${phase2_rc} phase3=${phase3_rc}"
  exit 1
fi

echo "Azure deprovisioner finished successfully."
