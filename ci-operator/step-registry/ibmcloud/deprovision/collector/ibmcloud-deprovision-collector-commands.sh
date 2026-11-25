#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export IBMCLOUD_CLI=ibmcloud
export IBMCLOUD_HOME=/output

# --- Login with retry (ported from openshift-ci-ipi-cleanup Jenkins job) ---
function ibmcloud_login() {
  local region="${1}"
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Logging into IBM Cloud in region ${region} ..."
  local successful=false
  for _ in $(seq 5); do
    if "${IBMCLOUD_CLI}" login -a https://cloud.ibm.com \
        --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -r "${region}" -q; then
      successful=true
      break
    fi
    sleep 15
  done
  if [[ "${successful}" == false ]]; then
    echo "ERROR: IBM Cloud login failed after 5 attempts. Exiting."
    exit 1
  fi
  echo "Login successful."
}

# --- Account safety check (ported from openshift-ci-ipi-cleanup Jenkins job) ---
# Verifies we are in the expected CI account before doing anything destructive.
function verify_account() {
  local expected_account="OpenShiftCI (b9db97fa92ce47ae8dbf40ec2318b9f4)"
  local successful=false
  local account_info
  for _ in $(seq 5); do
    if account_info=$("${IBMCLOUD_CLI}" target); then
      successful=true
      break
    fi
    sleep 15
  done
  if [[ "${successful}" == false ]]; then
    echo "ERROR: Failed to retrieve account info. Exiting."
    exit 1
  fi
  if ! echo "${account_info}" | awk '/Account:/{print $2" "$3}' \
      | grep "${expected_account}" > /dev/null; then
    echo "ERROR: Unexpected IBM Cloud account. Exiting."
    exit 1
  fi
  echo "Account verified: ${expected_account}"
}

# --- Wait helpers (ported from openshift-ci-ipi-cleanup Jenkins job) ---
function wait_for_cleanup() {
  local resources="${1}" filter="${2}"
  for _ in $(seq 10); do
    local count
    count=$("${IBMCLOUD_CLI}" is "${resources}" --all-resource-groups --output json \
      | jq --arg f "${filter}" '[.[] | select(.name | contains($f))] | length')
    if [[ "${count}" -eq 0 ]]; then
      return 0
    fi
    sleep 30
  done
  return 1
}

function wait_for_cos_cleanup() {
  local filter="${1}"
  for _ in $(seq 10); do
    local count
    count=$("${IBMCLOUD_CLI}" resource service-instances \
      --service-name cloud-object-storage --output json \
      | jq --arg f "${filter}" '[.[] | select(.name | contains($f))] | length')
    if [[ "${count}" -eq 0 ]]; then
      return 0
    fi
    sleep 30
  done
  return 1
}

# --- Resource cleanup (ported from openshift-ci-ipi-cleanup Jenkins job) ---
# Deletes all VPC and related resources matching the given filter string.
# Returns 1 if any step failed, 0 if all succeeded.
function cleanup_resources() {
  local filter="${1}"
  local failed=0

  echo "Performing cleanup using filter: ${filter}"

  "${IBMCLOUD_CLI}" target -g "${filter}"

  # Instances
  "${IBMCLOUD_CLI}" is instances --resource-group-name "${filter}" --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is ind -f % || failed=1
  wait_for_cleanup instances "${filter}" || failed=1

  # Load balancers
  "${IBMCLOUD_CLI}" is lbs --resource-group-name "${filter}" --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is lbd -f % || failed=1
  wait_for_cleanup lbs "${filter}" || failed=1

  # Subnets
  "${IBMCLOUD_CLI}" is subnets --resource-group-name "${filter}" --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is subnet-delete -f % || failed=1
  wait_for_cleanup subnets "${filter}" || failed=1

  # Public gateways
  "${IBMCLOUD_CLI}" is public-gateways --resource-group-name "${filter}" --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is public-gateway-delete -f % || failed=1
  wait_for_cleanup public-gateways "${filter}" || failed=1

  # VPCs
  "${IBMCLOUD_CLI}" is vpcs --resource-group-name "${filter}" --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is vpc-delete -f % || failed=1
  wait_for_cleanup vpcs "${filter}" || failed=1

  # Images (private only) — may persist after RG deletion, so scan all RGs
  "${IBMCLOUD_CLI}" is images --visibility private --all-resource-groups --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is image-delete -f % || failed=1
  wait_for_cleanup images "${filter}" || failed=1

  # Volumes — may persist after RG deletion, so scan all RGs
  "${IBMCLOUD_CLI}" is volumes --all-resource-groups --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" is volume-delete -f % || failed=1
  wait_for_cleanup volumes "${filter}" || failed=1

  # COS instances
  # TODO: cleanup the service key associated with COS instances as it may prevent deletion
  "${IBMCLOUD_CLI}" resource service-instances \
    --service-name cloud-object-storage --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" resource service-instance-delete -f % || failed=1
  wait_for_cos_cleanup "${filter}" || failed=1

  "${IBMCLOUD_CLI}" target --unset-resource-group

  return "${failed}"
}

# --- CIS DNS cleanup (ported from openshift-ci-ipi-cleanup Jenkins job) ---
# Paginates through all DNS records and deletes those matching the filter.
function cleanup_cis_dns() {
  local filter="${1}"
  local cis_instance domain_id total_pages dns_filter
  local dns_records_file
  dns_records_file="$(mktemp)"

  if [[ -f "${CLUSTER_PROFILE_DIR}/ibmcloud-cis" ]]; then
    cis_instance="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis")"
  else
    cis_instance="Openshift-IPI-CI-CIS"
  fi

  echo "Cleaning up CIS DNS records matching '${filter}' in instance ${cis_instance} ..."

  "${IBMCLOUD_CLI}" cis instance-set "${cis_instance}"

  domain_id=$("${IBMCLOUD_CLI}" cis domains --per-page 50 \
    | awk -v domain="${BASE_DOMAIN}" '$0 ~ domain {print $1}')

  if [[ -z "${domain_id}" ]]; then
    echo "Could not find domain ID for ${BASE_DOMAIN}, skipping DNS cleanup"
    rm -f "${dns_records_file}"
    return 0
  fi

  # DNS records do not contain the full infraID hash, so trim the last -<suffix>
  # but only if the filter is longer than 20 characters — ported exactly from Jenkins
  if [[ "${#filter}" -gt 20 ]]; then
    dns_filter="${filter%-*}"
  else
    dns_filter="${filter}"
  fi

  # Use IBMCLOUD_TRACE to extract total_pages from the API response metadata
  total_pages=$(IBMCLOUD_TRACE=true "${IBMCLOUD_CLI}" cis dns-records "${domain_id}" \
    |& grep "total_pages" | jq -r '.result_info.total_pages')

  echo "Checking ${total_pages} pages of CIS DNS records for filter: ${dns_filter}"

  for page in $(seq "${total_pages}"); do
    echo "----- Page ${page} -----"
    "${IBMCLOUD_CLI}" cis dns-records --page "${page}" "${domain_id}" \
      | awk -v f="${dns_filter}" '$0 ~ f {print $1}' >> "${dns_records_file}"
  done

  if [[ -s "${dns_records_file}" ]]; then
    xargs -I % sh -c "${IBMCLOUD_CLI} cis dns-record-delete ${domain_id} %" \
      < "${dns_records_file}"
  fi

  rm -f "${dns_records_file}"
  echo "CIS DNS cleanup complete."
}

# --- Resource group cleanup (ported from openshift-ci-ipi-cleanup Jenkins job) ---
function cleanup_resource_groups() {
  local filter="${1}"
  "${IBMCLOUD_CLI}" resource groups --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" resource group-delete -f %
}

# --- Post-cleanup verification (ported from ibm-openshift-ipi-destroy-cluster Jenkins job) ---
# Scans for any remaining resources after cleanup and logs them to ARTIFACT_DIR.
# Informational only — never affects the exit code.
function verify_cleanup() {
  local filter="${1}"
  local verify_dir="${ARTIFACT_DIR}/remaining-resources-${filter}"
  local remaining=false
  local result

  mkdir -p "${verify_dir}"

  for resource in image instance lb public-gateway subnet volume vpc; do
    result=$("${IBMCLOUD_CLI}" is "${resource}s" --all-resource-groups --output json \
      | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | "\(.id)\t\(.name)"') || true
    if [[ -n "${result}" ]]; then
      remaining=true
      echo "${result}" > "${verify_dir}/${resource}s.txt"
    fi
  done

  result=$("${IBMCLOUD_CLI}" resource service-instances \
    --service-name cloud-object-storage --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | "\(.id)\t\(.name)"') || true
  if [[ -n "${result}" ]]; then
    remaining=true
    echo "${result}" > "${verify_dir}/cos.txt"
  fi

  if [[ "${remaining}" == true ]]; then
    echo "WARNING: Remaining resources found for ${filter}. See ${verify_dir}."
  else
    echo "SUCCESS: No remaining resources found for ${filter}."
    rm -rf "${verify_dir}"
  fi
}

# --- Main ---
echo "IBM Cloud deprovision collector starting."
echo "Regions to sweep: ${REGIONS_TO_SWEEP}"
echo "Cluster TTL: ${CLUSTER_TTL}"
echo "Clusters older than $(date --date="${CLUSTER_TTL}") will be cleaned up."

"${IBMCLOUD_CLI}" version

cutoff_epoch=$(date --date="${CLUSTER_TTL}" +%s)
final_rc=0

for region in ${REGIONS_TO_SWEEP}; do
  echo "========================================"
  echo "Scanning region: ${region}"
  echo "========================================"

  ibmcloud_login "${region}"
  verify_account

  # Discover leaked clusters: VPCs matching the CI naming pattern older than CLUSTER_TTL.
  # Fail loudly if the discovery call itself fails (don't silently treat failure as empty).
  vpc_list=$(
    "${IBMCLOUD_CLI}" is vpcs --all-resource-groups --output json -q 2>/dev/null \
      | jq -r '.[] | select(.name | test("^ci-op-|^ci-ln-")) | [.id, .name, .created_at] | @tsv'
  )

  if [[ -z "${vpc_list}" ]]; then
    echo "No CI VPCs found in region ${region}."
    continue
  fi

  while IFS=$'\t' read -r _vpc_id vpc_name vpc_created_at; do
    [[ -z "${vpc_name}" ]] && continue

    vpc_created_epoch=$(date --date="${vpc_created_at}" +%s 2>/dev/null || echo 0)
    if [[ "${vpc_created_epoch}" -gt "${cutoff_epoch}" ]]; then
      echo "Skipping ${vpc_name} — created ${vpc_created_at}, within TTL."
      continue
    fi

    # infraID = VPC name with the "-vpc" suffix stripped
    infraID="${vpc_name%-vpc}"
    echo "Found leaked cluster: ${infraID} (VPC: ${vpc_name}, created: ${vpc_created_at})"

    set +o errexit

    cleanup_resources "${infraID}" || {
      echo "ERROR: resource cleanup failed for ${infraID}"
      final_rc=1
    }

    cleanup_cis_dns "${infraID}" || {
      echo "ERROR: CIS DNS cleanup failed for ${infraID}"
      final_rc=1
    }

    cleanup_resource_groups "${infraID}" || {
      echo "ERROR: resource group cleanup failed for ${infraID}"
      final_rc=1
    }

    verify_cleanup "${infraID}" || true

    set -o errexit

    echo "Cleanup complete for ${infraID}."
  done <<< "${vpc_list}"
done

if [[ "${final_rc}" -ne 0 ]]; then
  echo "ERROR: One or more cleanup operations failed."
  exit 1
fi

echo "IBM Cloud deprovision sweep complete."
