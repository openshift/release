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

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## Try the validation
ret=0

compute_node_cc_type=""
compute_node_maintenance_policy=""
if [[ -n "${COMPUTE_CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${COMPUTE_ON_HOST_MAINTENANCE}" ]]; then
  compute_node_cc_type="${COMPUTE_CONFIDENTIAL_COMPUTE}"
  compute_node_maintenance_policy="${COMPUTE_ON_HOST_MAINTENANCE}"
elif [[ -n "${CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${ON_HOST_MAINTENANCE}" ]]; then
  compute_node_cc_type="${CONFIDENTIAL_COMPUTE}"
  compute_node_maintenance_policy="${ON_HOST_MAINTENANCE}"
fi

control_plane_node_cc_type=""
control_plane_node_maintenance_policy=""
if [[ -n "${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${CONTROL_PLANE_ON_HOST_MAINTENANCE}" ]]; then
  control_plane_node_cc_type="${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}"
  control_plane_node_maintenance_policy="${CONTROL_PLANE_ON_HOST_MAINTENANCE}"
elif [[ -n "${CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${ON_HOST_MAINTENANCE}" ]]; then
  control_plane_node_cc_type="${CONFIDENTIAL_COMPUTE}"
  control_plane_node_maintenance_policy="${ON_HOST_MAINTENANCE}"
fi

echo "$(date -u --rfc-3339=seconds) - Checking Confidential Computing settings of cluster machines..."
readarray -t machines < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${machines[@]}"; do
  machine_name="${line%% *}"
  machine_zone="${line##* }"

  # "specified" corresponds to confidentialCompute settings in install-config
  # "expected" correspondds to the expected settings in "gcloud" outputs
  specified_cc_type=""
  specified_maintenance_policy=""
  if [[ "${machine_name}" =~ master ]]; then
    specified_cc_type="${control_plane_node_cc_type}"
    specified_maintenance_policy="${control_plane_node_maintenance_policy}"
  elif [[ "${machine_name}" =~ worker ]]; then
    specified_cc_type="${compute_node_cc_type}"
    specified_maintenance_policy="${compute_node_maintenance_policy}"
  else
    echo "$(date -u --rfc-3339=seconds) Unknown machine role for '${machine_name}', skipped."
    continue
  fi
  case "${specified_cc_type}" in
    Enabled)
      expected_cc_type="true"
    ;;
    AMDEncryptedVirtualization)
      expected_cc_type="SEV"
    ;;
    AMDEncryptedVirtualizationNestedPaging)
      expected_cc_type="SEV_SNP"
    ;;
    IntelTrustedDomainExtensions)
      expected_cc_type="TDX"
    ;;
    *)
      expected_cc_type="null"
    ;;
  esac

  gcloud compute instances describe "${machine_name}" --zone "${machine_zone}" --format json > "/tmp/${CLUSTER_NAME}-machine.json"
  cc_enable="$(jq -r -c .confidentialInstanceConfig.enableConfidentialCompute "/tmp/${CLUSTER_NAME}-machine.json")"
  cc_type="$(jq -r -c .confidentialInstanceConfig.confidentialInstanceType "/tmp/${CLUSTER_NAME}-machine.json")"
  on_host_maintenance="$(jq -r -c .scheduling.onHostMaintenance "/tmp/${CLUSTER_NAME}-machine.json")"

  if [[ "${expected_cc_type}" == "null" ]] && [[ "${cc_enable}" == "null" ]] && [[ "${cc_type}" == "null" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Confidential Computing is not enabled, PASSED for '${machine_name}'."
  elif [[ "${expected_cc_type}" != "null" ]]; then
    if [[ "${expected_cc_type}" == "true" ]] && [[ "${cc_enable}" == true ]]; then
      echo "$(date -u --rfc-3339=seconds) - Matched .enableConfidentialCompute '${cc_enable}' for '${machine_name}'."
    elif [[ "${expected_cc_type}" == "${cc_type}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - Matched .confidentialInstanceType '${cc_type}' for '${machine_name}'."
    else
      echo "$(date -u --rfc-3339=seconds) - Unexpected .enableConfidentialCompute '${cc_enable}' or unexpected .confidentialInstanceType '${cc_type}' for '${machine_name}'."
      ret=1
    fi
  fi

  if [[ "${specified_maintenance_policy^^}" == "${on_host_maintenance}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Matched .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
  else
    echo "$(date -u --rfc-3339=seconds) - Unexpected .onHostMaintenance '${on_host_maintenance}' for '${machine_name}'."
    ret=1
  fi
done

exit ${ret}
