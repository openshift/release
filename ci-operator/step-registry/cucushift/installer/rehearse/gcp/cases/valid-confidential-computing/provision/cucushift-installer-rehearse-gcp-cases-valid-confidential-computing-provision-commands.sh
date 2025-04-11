#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# -----------------------------------------
# OCP-60212 - [IPI-on-GCP] Install with invalid settings of Confidential Computing on GCP	
# -----------------------------------------

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
REGION=${LEASED_RESOURCE}

CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

patch=$(mktemp)
expected_err_msg=""
selected_cc_type=""
ret=0

declare -A cc_type_machine_series_dict=(
  [AMDEncryptedVirtualization]="c2d, n2d, c3d"
  [AMDEncryptedVirtualizationNestedPaging]="n2d"
  [IntelTrustedDomainExtensions]="c3"
  [Enabled]="c2d, n2d, c3d"
)

declare -A instance_type_supported_cc_type_dict=(
  [n2d-standard-4]="AMDEncryptedVirtualization AMDEncryptedVirtualizationNestedPaging Enabled"
  [c2d-standard-4]="AMDEncryptedVirtualization Enabled"
  [c3d-standard-4]="AMDEncryptedVirtualization Enabled"
  [c3-standard-4]="IntelTrustedDomainExtensions"
  [n2-standard-4]=""
)

declare -A instance_type_unsupported_cc_type_dict=(
  [n2d-standard-4]="IntelTrustedDomainExtensions"
  [c2d-standard-4]="IntelTrustedDomainExtensions AMDEncryptedVirtualizationNestedPaging"
  [c3d-standard-4]="IntelTrustedDomainExtensions AMDEncryptedVirtualizationNestedPaging"
  [c3-standard-4]="AMDEncryptedVirtualization AMDEncryptedVirtualizationNestedPaging Enabled"
  [n2-standard-4]="AMDEncryptedVirtualization AMDEncryptedVirtualizationNestedPaging Enabled IntelTrustedDomainExtensions"
)

function save_artifacts()
{
  local -r install_dir="$1"
  local -r testing_scenario_num="$2"

  set +o errexit
  current_time=$(date +%s)
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_${testing_scenario_num}_openshift_install-${current_time}.log"

  set -o errexit
}

function create_install_config()
{
  local cluster_name=$1
  local install_dir=$2

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${cluster_name}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    projectID: ${GOOGLE_PROJECT_ID}
    region: ${REGION}
publish: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
}

function compose_expected_err_msg()
{
  local -r instance_type="$1"
  local -r compute_cc_type="$2"
  local -r control_plane_cc_type="$3"
  local -r on_host_maintenance="$4"

  supported_cc_types=${instance_type_supported_cc_type_dict["${instance_type}"]}
  unsupported_cc_types=${instance_type_unsupported_cc_type_dict["${instance_type}"]}

  expected_err_msg=""
  if [[ "${on_host_maintenance}" != "Terminate" ]]; then
    expected_err_msg="controlPlane.platform.gcp.OnHostMaintenance: Invalid value: \\\"${on_host_maintenance}\\\": OnHostMaintenace must be set to Terminate when ConfidentialCompute is ${control_plane_cc_type}"
  fi

  set +e
  if echo "${unsupported_cc_types}" | grep -qw "${control_plane_cc_type}"; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}controlPlane.platform.gcp.type: Invalid value: \\\"${instance_type}\\\": Machine type do not support ${control_plane_cc_type}. Machine types supporting ${control_plane_cc_type}: ${cc_type_machine_series_dict[${control_plane_cc_type}]}"
  fi

  if [[ "${on_host_maintenance}" != "Terminate" ]]; then
    expected_err_msg="${expected_err_msg}, compute[0].platform.gcp.OnHostMaintenance: Invalid value: \\\"${on_host_maintenance}\\\": OnHostMaintenace must be set to Terminate when ConfidentialCompute is ${compute_cc_type}"
  fi

  if echo "${unsupported_cc_types}" | grep -qw "${compute_cc_type}"; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}compute[0].platform.gcp.type: Invalid value: \\\"${instance_type}\\\": Machine type do not support ${compute_cc_type}. Machine types supporting ${compute_cc_type}: ${cc_type_machine_series_dict[${compute_cc_type}]}"
  fi
  set -e
}

function random_choice()
{
  local -r cc_types_str="$1"

  IFS=' ' read -r -a cc_types_array <<< "${cc_types_str}"
  array_len="${#cc_types_array[@]}"
  selected_index=$(( $RANDOM%($array_len) ))
  selected_cc_type="${cc_types_array[${selected_index}]}"
}

function create_manifests()
{
  local -r instance_type="$1"
  local -r cc_types_str="$2"
  local -r on_host_maintenance="$3"
  local -r testing_scenario_num="$4"
  local -r success_flag="$5"

  cluster_name="${CLUSTER_PREFIX}${testing_scenario_num}"
  install_dir="/tmp/${cluster_name}"
  mkdir -p "${install_dir}" 2>/dev/null
  create_install_config "${cluster_name}" "${install_dir}"

  random_choice "${cc_types_str}"
  compute_cc_type="${selected_cc_type}"
  random_choice "${cc_types_str}"
  control_plane_cc_type="${selected_cc_type}"

  cat > "${patch}" << EOF
compute:
- name: worker
  platform:
    gcp:
      type: ${instance_type}
      confidentialCompute: ${compute_cc_type}
      onHostMaintenance: ${on_host_maintenance}
controlPlane:
  name: master
  platform:
    gcp:
      type: ${instance_type}
      confidentialCompute: ${control_plane_cc_type}
      onHostMaintenance: ${on_host_maintenance}
EOF
  yq-go m -x -i "${install_dir}/install-config.yaml" "${patch}"
  #yq-go r "${install_dir}/install-config.yaml" platform
  #yq-go r "${install_dir}/install-config.yaml" compute
  #yq-go r "${install_dir}/install-config.yaml" controlPlane

  result=0
  openshift-install create manifests --dir ${install_dir} || result=1

  if ! "${success_flag}"; then
    compose_expected_err_msg "${instance_type}" "${compute_cc_type}" "${control_plane_cc_type}" "${on_host_maintenance}"    
    echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: the expected error messages are '${expected_err_msg}'"

    if ! grep -qF "${expected_err_msg}" ${install_dir}/.openshift_install.log; then
      echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: FAILED, the expected error messages are not found in '.openshift_install.log'."
      ret=$((ret+1))
    else
      echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: PASSED, found the expected error messages in '.openshift_install.log'."
    fi
  else
    if [[ ${result} -eq 0 ]]; then
      echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: PASSED, successfully created manifests."
    else
      echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: FAILED, failed to create manifests."
      ret=$((ret+1))
    fi
  fi

  save_artifacts "${install_dir}" "${testing_scenario_num}"
  rm -fr "${install_dir}"
}


## main
num=0
for instance_type in "${!instance_type_unsupported_cc_type_dict[@]}"
do
  supported_cc_types=${instance_type_supported_cc_type_dict["${instance_type}"]}
  unsupported_cc_types=${instance_type_unsupported_cc_type_dict["${instance_type}"]}

  if [[ "${unsupported_cc_types}" != "" ]]; then
    num=$((num+1))
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + unsupported Confidential Computing types..."
    create_manifests "${instance_type}" "${unsupported_cc_types}" "Terminate" "${num}" false

    num=$((num+1))
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + unsupported Confidential Computing types + 'onHostMaintenance: Migrate'..."
    create_manifests "${instance_type}" "${unsupported_cc_types}" "Migrate" "${num}" false
  fi

  if [[ "${supported_cc_types}" != "" ]]; then
    num=$((num+1))
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + supported Confidential Computing types..."
    create_manifests "${instance_type}" "${supported_cc_types}" "Terminate" "${num}" true

    num=$((num+1))
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + supported Confidential Computing types + 'onHostMaintenance: Migrate'..."
    create_manifests "${instance_type}" "${supported_cc_types}" "Migrate" "${num}" false
  fi
done

exit $ret
