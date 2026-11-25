#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export IBMCLOUD_CLI=ibmcloud
export IBMCLOUD_HOME=/output

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found — cluster was never installed."
  exit 0
fi

infraID=$(jq -r '.infraID'                    "${SHARED_DIR}/metadata.json")
region=$(jq  -r '.ibmcloud.region'            "${SHARED_DIR}/metadata.json")

if [[ -z "${infraID}" || "${infraID}" == "null" ]]; then
  echo "Skipping: infraID not found in metadata.json."
  exit 0
fi
if [[ -z "${region}" || "${region}" == "null" ]]; then
  echo "Skipping: region not found in metadata.json."
  exit 0
fi

echo "Post-deprovision cleanup for cluster: ${infraID} in region: ${region}"

# --- Login with retry ---
function ibmcloud_login() {
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

# --- Account safety check ---
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

# --- Wait helpers ---
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

# --- Resource cleanup ---
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
  "${IBMCLOUD_CLI}" resource service-instances \
    --service-name cloud-object-storage --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" resource service-instance-delete -f % || failed=1
  wait_for_cos_cleanup "${filter}" || failed=1

  "${IBMCLOUD_CLI}" target --unset-resource-group

  return "${failed}"
}

# --- CIS DNS cleanup ---
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

  if [[ "${#filter}" -gt 20 ]]; then
    dns_filter="${filter%-*}"
  else
    dns_filter="${filter}"
  fi

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

# --- Resource group cleanup ---
function cleanup_resource_groups() {
  local filter="${1}"
  "${IBMCLOUD_CLI}" resource groups --output json \
    | jq -r --arg f "${filter}" '.[] | select(.name | contains($f)) | .id' \
    | xargs -r -I % "${IBMCLOUD_CLI}" resource group-delete -f %
}

# --- Post-cleanup verification ---
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
    echo "WARNING: Remaining resources found for ${infraID}. See ${verify_dir}."
  else
    echo "SUCCESS: No remaining resources found for ${infraID}."
    rm -rf "${verify_dir}"
  fi
}

# --- Main ---
"${IBMCLOUD_CLI}" version

ibmcloud_login
verify_account

set +o errexit

echo "--- Step 1: ccoctl service ID cleanup ---"
if ccoctl ibmcloud delete-service-id \
    --credentials-requests-dir "${SHARED_DIR}" \
    --name "${infraID}" 2>/dev/null; then
  echo "ccoctl service ID cleanup complete."
else
  echo "WARNING: ccoctl service ID cleanup failed or nothing to delete."
fi

echo "--- Step 2: VPC resource cleanup ---"
cleanup_resources "${infraID}" || echo "WARNING: resource cleanup had failures for ${infraID}"

echo "--- Step 3: CIS DNS cleanup ---"
cleanup_cis_dns "${infraID}" || echo "WARNING: CIS DNS cleanup had failures for ${infraID}"

echo "--- Step 4: Resource group cleanup ---"
cleanup_resource_groups "${infraID}" || echo "WARNING: resource group cleanup had failures for ${infraID}"

echo "--- Step 5: Verification ---"
verify_cleanup "${infraID}" || true

set -o errexit

echo "Post-deprovision cleanup complete for ${infraID}."
