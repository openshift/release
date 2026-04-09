#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" == *"proxy"* || "$CONFIG_TYPE" == *"dualstack"* || "$CONFIG_TYPE" == *"singlestackv6"* ]]; then
    echo "Skipping step due to CONFIG_TYPE being '${CONFIG_TYPE}'."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
if [[ "${HIVE_OSP_RESOURCE}" == "true" ]]; then 
  HIVE_CLUSTER_NAME="${CLUSTER_NAME}-hive"
  echo "${HIVE_CLUSTER_NAME}" > "${SHARED_DIR}/HIVE_CLUSTER_NAME" || { echo "Failed to write HIVE_CLUSTER_NAME"; exit 1; }
fi

OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

collect_artifacts() {
  for f in API_IP INGRESS_IP HCP_INGRESS_IP DELETE_FIPS; do
    if [[ -f "${SHARED_DIR}/${f}" ]]; then
      cp "${SHARED_DIR}/${f}" "${ARTIFACT_DIR}/"
    fi
  done

  if [[ "${HIVE_OSP_RESOURCE}" == "true" ]]; then
    for m in HIVE_FIP_API HIVE_FIP_INGRESS; do
      if [[ -f "${SHARED_DIR}/${m}" ]]; then
        cp "${SHARED_DIR}/${m}" "${ARTIFACT_DIR}/"
      else
        echo "Error: required file ${SHARED_DIR}/${m} not found!" >&2
        exit 1
      fi
    done
  fi
}
trap collect_artifacts EXIT TERM

create_fip() {
  local desc="$1"
  local output_ip_file="$2"
  local output_delete_file="$3"
  local cluster_name="$4"
  
  echo "Creating ${desc} floating IP"
  
  local fip_json
  fip_json=$(openstack floating ip create \
    --description "${cluster_name}.${desc}-fip" \
    --tag "PROW_CLUSTER_NAME=${cluster_name}" \
    --tag "PROW_JOB_ID=${PROW_JOB_ID}" \
    "$OPENSTACK_EXTERNAL_NETWORK" \
    --format json -c floating_ip_address -c id)
  
  jq -r '.floating_ip_address' <<<"$fip_json" > "${output_ip_file}"
  jq -r '.id' <<<"$fip_json" >> "${output_delete_file}"
}

if [[ "${API_FIP_ENABLED}" == "true" ]]; then
  create_fip "api" "${SHARED_DIR}/API_IP" "${SHARED_DIR}/DELETE_FIPS" "${CLUSTER_NAME}"
fi

if [[ "${INGRESS_FIP_ENABLED}" == "true" ]]; then
  create_fip "ingress" "${SHARED_DIR}/INGRESS_IP" "${SHARED_DIR}/DELETE_FIPS" "${CLUSTER_NAME}"
fi

if [[ "${HCP_INGRESS_FIP_ENABLED}" == "true" ]]; then
  create_fip "hcp-ingress" "${SHARED_DIR}/HCP_INGRESS_IP" "${SHARED_DIR}/DELETE_FIPS" "${CLUSTER_NAME}"
fi

if [[ "${HIVE_OSP_RESOURCE}" == "true" ]]; then
  create_fip "hive-api" "${SHARED_DIR}/HIVE_FIP_API" "${SHARED_DIR}/DELETE_FIPS" "${HIVE_CLUSTER_NAME}"
  create_fip "hive-ingress" "${SHARED_DIR}/HIVE_FIP_INGRESS" "${SHARED_DIR}/DELETE_FIPS" "${HIVE_CLUSTER_NAME}"
fi
