#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
export AZURE_CREDENTIALS_FILE=/etc/hypershift-ci-jobs-self-managed-azure/credentials.json

# Returns 0 if the resource group name matches CI naming conventions.
# Management cluster RGs: {10-hex}-mgmt-{10-hex}-mgmt (with optional vnet-/nsg- infix)
# Guest cluster RGs: {20-hex}-{5..20-hex} (with optional vnet-/nsg- infix)
# V2 self-managed guest RGs: {type}-{10hex}-{type}-{9-10hex}[-{suffix}]
#   create-guests passes the cluster name as the infra ID, so current guest RGs
#   have no suffix; older ones do.
#   e.g., public-ea334332a2-public-ea334332a2
#         oauth-lb-ea334332a2-vnet-oauth-lb-ea334332a2
#         public-ea334332a2-public-ea334332a2-dx4l4
is_ci_rg() {
  local name="$1"
  [[ "$name" =~ ^[0-9a-f]{10}-mgmt-((vnet|nsg)-)?[0-9a-f]{10}-mgmt$ ]] && return 0
  [[ "$name" =~ ^[0-9a-f]{20}-((vnet|nsg)-)?[0-9a-f]{5,20}$ ]] && return 0
  [[ "$name" =~ ^[a-z]([a-z-]*[a-z])?-[0-9a-f]{10}-((vnet|nsg)-)?[a-z]([a-z-]*[a-z])?-[0-9a-f]{9,10}(-[a-z0-9]+)?$ ]] && return 0
  return 1
}

# Prints the infra-ID prefix of a CI resource group: the job hash for
# management and v2 guest groups, the first 20 hex chars for legacy guests.
rg_job_prefix() {
  local name="$1"
  if [[ "${name}" == *-mgmt-* ]]; then
    # Management: {10hex}-mgmt-[vnet-|nsg-]{10hex}-mgmt → {10hex}
    echo "${name%%-mgmt-*}"
  elif [[ "${name}" =~ ^[0-9a-f]{20} ]]; then
    # Legacy guest cluster: prefix is the first 20 hex chars
    echo "${name:0:20}"
  elif [[ "${name}" =~ -([0-9a-f]{10})- ]]; then
    # V2 self-managed guest: extract the 10-hex job hash
    # e.g., public-ea334332a2-public-ea334332a2 → ea334332a2
    echo "${BASH_REMATCH[1]}"
  fi
}

# Prints the state of the Prow job with the given ID: a ProwJob state such as
# pending or success, or "gone" when Prow no longer has the job. Sinker removes
# only completed ProwJobs, so "gone" means the job is not running. Returns 1
# when Prow cannot be reached or does not report a state.
prow_job_state() {
  local job_id="$1" response http_code body state
  [[ "${job_id}" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  response="$(curl --silent --show-error --max-time 30 --write-out '\n%{http_code}' \
    "https://prow.ci.openshift.org/prowjob?prowjob=${job_id}")" || return 1
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  case "${http_code}" in
    200)
      state="$(awk '/^status:/ {in_status=1; next} /^[^ ]/ {in_status=0} in_status && /^  state:/ {print $2; exit}' <<< "${body}")"
      [[ -n "${state}" ]] || return 1
      echo "${state}"
      ;;
    404)
      # Deck answers every failed lookup with 404 "ProwJob not found: <error>".
      # Only a Kubernetes NotFound error names the missing job.
      [[ "${body}" == *"prowjobs.prow.k8s.io \"${job_id}\" not found"* ]] || return 1
      echo "gone"
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns 0 if the job state from prow_job_state means the job has finished.
job_finished() {
  case "$1" in
    success|failure|aborted|error|gone) return 0 ;;
  esac
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
# "clusters" namespace that are older than CLUSTER_TTL and whose Prow job,
# from the hypershift.openshift.io/prow-job-id annotation, has finished.
# A job can run past CLUSTER_TTL, so age alone does not mean it is orphaned.
##############################################################################
PHASE1_TIMEOUT="${PHASE1_TIMEOUT:-14400}"

# Job hashes of HostedClusters whose Prow job is not confirmed finished.
# Phase 2 keeps their resource groups. Filled by phase1_hc_pruner.
declare -A RUNNING_JOB_PREFIXES=()
HC_INVENTORY_OK=false
# Phase 2 deletes only resource groups created CLUSTER_TTL before the
# HostedCluster inventory. A running job creates its HostedCluster minutes
# after its resource groups, so any such group's job is in the inventory.
RG_AGE_CUTOFF=""

phase1_hc_pruner() {
  echo "=== Phase 1: HostedCluster Pruner (budget: ${PHASE1_TIMEOUT}s) ==="
  local had_failure=0
  local phase1_start
  phase1_start="$(date -u +%s)"

  local ttl_seconds=$(( $(date -u +%s) - $(date -u --date="${CLUSTER_TTL}" +%s) ))
  RG_AGE_CUTOFF="$(date -u --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M:%SZ')"
  local hc_list
  if ! hc_list="$(oc get hostedcluster -n clusters -o json | jq -r \
    --argjson timestamp "${ttl_seconds}" \
    '.items[] | [
      .metadata.name,
      (.metadata.annotations["hypershift.openshift.io/prow-job-id"] // "-"),
      (.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp)
    ] | @tsv')"; then
    echo "Phase 1: failed to list HostedClusters."
    return 1
  fi

  local hostedclusters=()
  local hc_name job_id is_stale state
  while IFS=$'\t' read -r hc_name job_id is_stale; do
    [[ -z "${hc_name}" ]] && continue
    # Leave the inventory incomplete so Phase 2 does not trust it.
    if (( $(date -u +%s) - phase1_start >= PHASE1_TIMEOUT )); then
      echo "Phase 1: time budget exhausted while checking jobs, skipping the remaining HostedClusters."
      return 1
    fi
    if [[ "${job_id}" == "-" ]]; then
      state="unannotated"
    elif ! state="$(prow_job_state "${job_id}")"; then
      state="unknown"
    fi
    if ! job_finished "${state}" && [[ "${hc_name}" =~ ^([0-9a-f]{10})- ]]; then
      RUNNING_JOB_PREFIXES["${BASH_REMATCH[1]}"]=1
    fi
    [[ "${is_stale}" == "true" ]] || continue
    if job_finished "${state}"; then
      hostedclusters+=("${hc_name}")
    elif [[ "${state}" == "unannotated" ]]; then
      echo "Keeping stale HostedCluster ${hc_name}: it has no prow-job-id annotation."
    elif [[ "${state}" == "unknown" ]]; then
      echo "Keeping stale HostedCluster ${hc_name}: could not get the state of job ${job_id} from Prow."
      had_failure=$((had_failure+1))
    else
      echo "Keeping stale HostedCluster ${hc_name}: job ${job_id} is still ${state}."
    fi
  done <<< "${hc_list}"
  HC_INVENTORY_OK=true

  if [[ ${#hostedclusters[@]} -eq 0 ]]; then
    echo "No stale HostedClusters with finished jobs found."
  fi

  for hc in "${hostedclusters[@]}"; do
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
        --cluster-grace-period 20m \
        --force || had_failure=$((had_failure+1))
    fi
  done

  if [[ ${had_failure} -ne 0 ]]; then
    echo "Phase 1: ${had_failure} HostedCluster check(s) or destroy(s) failed."
    return 1
  fi
  echo "Phase 1: complete."
}

##############################################################################
# Azure login, shared by Phases 2 and 3.
##############################################################################
AZURE_SUBSCRIPTION_ID=""

azure_login() {
  local login_rc=0
  # Disable tracing due to credential handling
  [[ $- == *x* ]] && local was_tracing=true || local was_tracing=false
  set +x
  az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_CREDENTIALS_FILE}")" \
    -p "$(jq -r .clientSecret "${AZURE_CREDENTIALS_FILE}")" \
    --tenant "$(jq -r .tenantId "${AZURE_CREDENTIALS_FILE}")" \
    --output none || login_rc=$?
  $was_tracing && set -x
  [[ ${login_rc} -eq 0 ]] || return 1

  AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId "${AZURE_CREDENTIALS_FILE}")" || return 1
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" || return 1
}

##############################################################################
# Phase 2: Orphaned Resource Group Sweep
#
# Lists all resource groups and deletes CI-created ones older than
# CLUSTER_TTL, except those of jobs that Phase 1 found still running.
##############################################################################
phase2_rg_sweep() {
  echo "=== Phase 2: Orphaned Resource Group Sweep ==="

  # Without the HostedCluster inventory, a running job's groups look orphaned.
  if [[ "${HC_INVENTORY_OK}" != "true" ]]; then
    echo "Phase 2: no HostedCluster inventory from Phase 1, skipping resource group sweep."
    return 1
  fi
  set +o nounset
  local running_prefixes=("${!RUNNING_JOB_PREFIXES[@]}")
  set -o nounset
  echo "Keeping resource groups of ${#running_prefixes[@]} job(s) not confirmed finished: ${running_prefixes[*]:-}"

  local rg_age_cutoff="${RG_AGE_CUTOFF}"
  echo "Deleting CI resource groups created before ${rg_age_cutoff} ..."

  # Use ARM REST API with $expand=createdTime since az group list does not
  # return createdTime by default. Paginate via nextLink.
  local rg_json="[]"
  local next_url="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourcegroups?api-version=2021-04-01&\$expand=createdTime"
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

    local rg_prefix
    rg_prefix="$(rg_job_prefix "${rg_name}")"
    if [[ -n "${rg_prefix}" && -n "${RUNNING_JOB_PREFIXES[${rg_prefix}]:-}" ]]; then
      echo "Keeping resource group ${rg_name}: its job is not confirmed finished."
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
# For each CI zone, lists the DNS records, then builds the set of active
# infra-ID prefixes from surviving resource groups, then deletes the records
# that don't match any active prefix.
##############################################################################

# Prints the infra-ID prefix of each surviving CI resource group, one per line.
# The prefix is the base infra-ID (first component before any vnet-/nsg- infix).
active_ci_prefixes() {
  local rg_list rg_name rg_state
  rg_list="$(az group list --query "[].{name:name, state:properties.provisioningState}" -o tsv)" || return 1
  while IFS=$'\t' read -r rg_name rg_state; do
    [[ -z "${rg_name}" ]] && continue
    [[ "${rg_state}" == "Deleting" ]] && continue
    is_ci_rg "${rg_name}" || continue
    rg_job_prefix "${rg_name}"
  done <<< "${rg_list}"
  return 0
}

phase3_dns_sweep() {
  echo "=== Phase 3: Orphaned DNS Record Sweep ==="
  local had_failure=0

  # Zone to resource group. The root's external DNS zone lives with the root.
  local -A dns_zones=(
    ["hcp-sm-azure.azure.devcluster.openshift.com"]="os4-common"
    ["sm-azure-root-ci.hcp-sm-azure.azure.devcluster.openshift.com"]="sm-azure-root-ci-shared-rg"
  )

  for zone in "${!dns_zones[@]}"; do
    local dns_rg="${dns_zones[${zone}]}"
    echo "Sweeping DNS zone: ${zone}"
    local deleted_in_zone=0 would_delete_in_zone=0
    local records
    if ! records="$(az network dns record-set list \
      --resource-group "${dns_rg}" \
      --zone-name "${zone}" \
      --query "[].{name:name, type:type}" -o tsv)"; then
      echo "Phase 3: failed to list DNS records in ${zone}."
      had_failure=$((had_failure+1))
      continue
    fi

    # Take the inventory after listing the records. A cluster creates its
    # resource groups before it publishes records, so every listed record of a
    # live cluster has its prefix here. Without the inventory every CI record
    # looks orphaned, so skip the zone if it fails.
    local prefixes
    if ! prefixes="$(active_ci_prefixes | sort -u)"; then
      echo "Phase 3: failed to list resource groups, skipping ${zone}."
      had_failure=$((had_failure+1))
      continue
    fi
    local prefix_keys=()
    if [[ -n "${prefixes}" ]]; then
      mapfile -t prefix_keys <<< "${prefixes}"
    fi
    echo "Found ${#prefix_keys[@]} active CI cluster prefix(es): ${prefix_keys[*]:-}"
    # With no recognized prefix, every CI-looking record would look orphaned,
    # which more likely means the inventory missed something than that no
    # cluster owns any record.
    if [[ ${#prefix_keys[@]} -eq 0 ]]; then
      echo "WARNING: Phase 3: no active CI cluster prefixes found, skipping deletions in ${zone}."
      continue
    fi

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
          would_delete_in_zone=$((would_delete_in_zone+1))
        else
          echo "Deleting orphaned DNS record: ${record_name} (${record_type}) in ${zone}"
          if az network dns record-set "${record_type,,}" delete \
            --resource-group "${dns_rg}" \
            --zone-name "${zone}" \
            --name "${record_name}" \
            --yes; then
            deleted_in_zone=$((deleted_in_zone+1))
          else
            had_failure=$((had_failure+1))
          fi
        fi
      fi
    done <<< "${records//Microsoft.Network\/dnszones\//}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] Would delete ${would_delete_in_zone} orphaned record(s) from ${zone}."
    else
      echo "Deleted ${deleted_in_zone} orphaned record(s) from ${zone}."
    fi
  done

  if [[ ${had_failure} -ne 0 ]]; then
    echo "Phase 3: ${had_failure} DNS sweep operation(s) failed."
    return 1
  fi
  echo "Phase 3: complete."
}

##############################################################################
# Main
##############################################################################
phase1_hc_pruner || phase1_rc=$?
if azure_login; then
  phase2_rg_sweep || phase2_rc=$?
  phase3_dns_sweep || phase3_rc=$?
else
  echo "Failed to log in to Azure, skipping Phases 2 and 3."
  phase2_rc=1
  phase3_rc=1
fi

if [[ ${phase1_rc} -ne 0 || ${phase2_rc} -ne 0 || ${phase3_rc} -ne 0 ]]; then
  echo "Failures detected: phase1=${phase1_rc} phase2=${phase2_rc} phase3=${phase3_rc}"
  exit 1
fi

echo "Azure deprovisioner finished successfully."
