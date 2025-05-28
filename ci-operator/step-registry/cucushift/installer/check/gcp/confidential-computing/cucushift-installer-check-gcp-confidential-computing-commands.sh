#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0

control_plane_node_cc_type=""
compute_node_cc_type=""
control_plane_node_maintenance_policy=""
compute_node_maintenance_policy=""
if [[ -n "${CONFIDENTIAL_COMPUTE}" ]]; then
  control_plane_node_cc_type="${CONFIDENTIAL_COMPUTE}"
  compute_node_cc_type="${CONFIDENTIAL_COMPUTE}"
fi
if [[ -n "${ON_HOST_MAINTENANCE}" ]]; then
  control_plane_node_maintenance_policy="${ON_HOST_MAINTENANCE}"
  compute_node_maintenance_policy="${ON_HOST_MAINTENANCE}"
fi
if [[ -n "${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}" ]]; then
  control_plane_node_cc_type="${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}"
fi
if [[ -n "${CONTROL_PLANE_ON_HOST_MAINTENANCE}" ]]; then
  control_plane_node_maintenance_policy="${CONTROL_PLANE_ON_HOST_MAINTENANCE}"
fi
if [[ -n "${COMPUTE_CONFIDENTIAL_COMPUTE}" ]]; then
  compute_node_cc_type="${COMPUTE_CONFIDENTIAL_COMPUTE}"
fi
if [[ -n "${COMPUTE_ON_HOST_MAINTENANCE}" ]]; then
  compute_node_maintenance_policy="${COMPUTE_ON_HOST_MAINTENANCE}"
fi

declare -A cc_type_mapping
cc_type_mapping["Enabled"]="true"
cc_type_mapping["AMDEncryptedVirtualization"]="SEV"
cc_type_mapping["AMDEncryptedVirtualizationNestedPaging"]="SEV_SNP"
cc_type_mapping["IntelTrustedDomainExtensions"]="TDX"

echo "$(date -u --rfc-3339=seconds) - INFO: Checking the Confidential Computing settings of the control-plane machines..."
oc get nodes -l node-role.kubernetes.io/master -o json > /tmp/cluster_nodes.json
for line in $(jq '.items[].spec.providerID' "/tmp/cluster_nodes.json"); do
  machine_name=$(echo "${line}" | cut -d\/ -f5)
  machine_name="${machine_name%\"}"
  machine_zone=$(echo "${line}" | cut -d\/ -f4)
  cmd="gcloud compute instances describe ${machine_name} --zone ${machine_zone} --format json > /tmp/${machine_name}.json"
  echo "Running Command: '${cmd}'"
  eval "${cmd}"

  if [[ -n  "${control_plane_node_cc_type}" ]]; then
    expected_cc_type="${cc_type_mapping[$control_plane_node_cc_type]}"
    if [[ "${expected_cc_type}" == "true" ]]; then
      cc_settings="$(jq -r -c .confidentialInstanceConfig.enableConfidentialCompute "/tmp/${machine_name}.json")"
    else
      cc_settings="$(jq -r -c .confidentialInstanceConfig.confidentialInstanceType "/tmp/${machine_name}.json")"
    fi
    if [[ "${expected_cc_type}" != "${cc_settings}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - ERROR: Unmatched .confidentialInstanceConfig '${cc_settings}' for '${machine_name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - INFO: Matched .confidentialInstanceConfig '${cc_settings}' for '${machine_name}'."
    fi
  fi

  if [[ -n  "${control_plane_node_maintenance_policy}" ]]; then
    on_host_maintenance="$(jq -r -c .scheduling.onHostMaintenance "/tmp/${machine_name}.json")"
    if [[ "${control_plane_node_maintenance_policy^^}" == "${on_host_maintenance}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - INFO: Matched .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
    else
      echo "$(date -u --rfc-3339=seconds) - ERROR: Unexpected .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
      ret=1
    fi
  fi
done

echo "$(date -u --rfc-3339=seconds) - INFO: Checking the Confidential Computing settings of the compute/worker machines..."
oc get nodes -l node-role.kubernetes.io/worker -o json > /tmp/cluster_nodes.json
for line in $(jq '.items[].spec.providerID' "/tmp/cluster_nodes.json"); do
  machine_name=$(echo "${line}" | cut -d\/ -f5)
  machine_name="${machine_name%\"}"
  machine_zone=$(echo "${line}" | cut -d\/ -f4)
  cmd="gcloud compute instances describe ${machine_name} --zone ${machine_zone} --format json > /tmp/${machine_name}.json"
  echo "Running Command: '${cmd}'"
  eval "${cmd}"

  if [[ -n  "${compute_node_cc_type}" ]]; then
    expected_cc_type="${cc_type_mapping[$compute_node_cc_type]}"
    if [[ "${expected_cc_type}" == "true" ]]; then
      cc_settings="$(jq -r -c .confidentialInstanceConfig.enableConfidentialCompute "/tmp/${machine_name}.json")"
    else
      cc_settings="$(jq -r -c .confidentialInstanceConfig.confidentialInstanceType "/tmp/${machine_name}.json")"
    fi
    if [[ "${expected_cc_type}" != "${cc_settings}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - ERROR: Unmatched .confidentialInstanceConfig '${cc_settings}' for '${machine_name}'."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - INFO: Matched .confidentialInstanceConfig '${cc_settings}' for '${machine_name}'."
    fi
  fi

  if [[ -n  "${compute_node_maintenance_policy}" ]]; then
    on_host_maintenance="$(jq -r -c .scheduling.onHostMaintenance "/tmp/${machine_name}.json")"
    if [[ "${compute_node_maintenance_policy^^}" == "${on_host_maintenance}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - INFO: Matched .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
    else
      echo "$(date -u --rfc-3339=seconds) - ERROR: Unexpected .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
      ret=1
    fi
  fi
done

exit $ret