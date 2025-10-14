#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# -----------------------------------------
# OCP-60212 - [IPI-on-GCP] Install with invalid settings of Confidential Computing on GCP	
# -----------------------------------------

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export INSTALLER_BINARY="openshift-install"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
fi
${INSTALLER_BINARY} version

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
REGION=${LEASED_RESOURCE}

CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

patch=$(mktemp)
expected_err_msg=""
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
  local current_time

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
  local -r cluster_name=$1
  local -r install_dir=$2

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
  local -r install_config_file="$1"
  # controlPlane
  local instance_type1 on_host_maintenance1 cc_type1 unsupported_cc_types1
  # compute
  local instance_type2 on_host_maintenance2 cc_type2 unsupported_cc_types2

  instance_type1=$(yq-go r "${install_config_file}" controlPlane.platform.gcp.type)
  if [[ -z "${instance_type1}" ]]; then
    instance_type1=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.type)
  fi

  instance_type2=$(yq-go r "${install_config_file}" compute[0].platform.gcp.type)
  if [[ -z "${instance_type2}" ]]; then
    instance_type2=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.type)
  fi

  on_host_maintenance1=$(yq-go r "${install_config_file}" controlPlane.platform.gcp.onHostMaintenance)
  if [[ -z "${on_host_maintenance1}" ]]; then
    on_host_maintenance1=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.onHostMaintenance)
  fi

  on_host_maintenance2=$(yq-go r "${install_config_file}" compute[0].platform.gcp.onHostMaintenance)
  if [[ -z "${on_host_maintenance2}" ]]; then
    on_host_maintenance2=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.onHostMaintenance)
  fi

  cc_type1=$(yq-go r "${install_config_file}" controlPlane.platform.gcp.confidentialCompute)
  if [[ -z "${cc_type1}" ]]; then
    cc_type1=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.confidentialCompute)
  fi

  cc_type2=$(yq-go r "${install_config_file}" compute[0].platform.gcp.confidentialCompute)
  if [[ -z "${cc_type2}" ]]; then
    cc_type2=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.confidentialCompute)
  fi

  unsupported_cc_types1=${instance_type_unsupported_cc_type_dict["${instance_type1}"]}
  unsupported_cc_types2=${instance_type_unsupported_cc_type_dict["${instance_type2}"]}

  expected_err_msg=""
  if [[ "${on_host_maintenance1}" != "Terminate" ]]; then
    expected_err_msg="controlPlane.platform.gcp.onHostMaintenance: Invalid value: \"${on_host_maintenance1}\": onHostMaintenace must be set to Terminate when confidentialCompute is ${cc_type1}"
  fi

  set +o errexit
  if echo "${unsupported_cc_types1}" | grep -qw "${cc_type1}"; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}controlPlane.platform.gcp.type: Invalid value: \"${instance_type1}\": Machine type does not support a Confidential Compute value of ${cc_type1}. Machine types supporting ${cc_type1}: ${cc_type_machine_series_dict[${cc_type1}]}"
  fi

  if [[ "${on_host_maintenance2}" != "Terminate" ]]; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}compute[0].platform.gcp.onHostMaintenance: Invalid value: \"${on_host_maintenance2}\": onHostMaintenace must be set to Terminate when confidentialCompute is ${cc_type2}"
  fi

  if echo "${unsupported_cc_types2}" | grep -qw "${cc_type2}"; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}compute[0].platform.gcp.type: Invalid value: \"${instance_type2}\": Machine type does not support a Confidential Compute value of ${cc_type2}. Machine types supporting ${cc_type2}: ${cc_type_machine_series_dict[${cc_type2}]}"
  fi
  set -o errexit
}

function random_choice()
{
  local -r cc_types_str="$1"
  local array_len selected_index

  IFS=' ' read -r -a cc_types_array <<< "${cc_types_str}"
  array_len="${#cc_types_array[@]}"
  selected_index=$(( $RANDOM%($array_len) ))
  echo "${cc_types_array[${selected_index}]}"
}

function create_manifests()
{
  local -r instance_type="$1"
  local -r cc_types_str="$2"
  local -r on_host_maintenance="$3"
  local -r testing_scenario_num="$4"
  local -r success_flag="$5"
  local cluster_name install_dir compute_cc_type control_plane_cc_type default_machine_platform_cc_type result tmp_output rand_int

  tmp_output=$(mktemp)
  cluster_name="${CLUSTER_PREFIX}${testing_scenario_num}"
  install_dir="/tmp/${cluster_name}"
  mkdir -p "${install_dir}" 2>/dev/null
  create_install_config "${cluster_name}" "${install_dir}"

  compute_cc_type=$(random_choice "${cc_types_str}")
  control_plane_cc_type=$(random_choice "${cc_types_str}")
  default_machine_platform_cc_type=$(random_choice "${cc_types_str}")

  rand_int=$(( $RANDOM%3 ))
  if [[ $rand_int -eq 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Use 'default_machine_platform_cc_type'..."
    cat > "${patch}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      confidentialCompute: ${default_machine_platform_cc_type}
      onHostMaintenance: ${on_host_maintenance}
compute:
- name: worker
  platform:
    gcp:
      type: ${instance_type}
controlPlane:
  name: master
  platform:
    gcp:
      type: ${instance_type}
EOF
  elif [[ $rand_int -eq 1 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Use 'compute_cc_type'/'control_plane_cc_type'..."
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
  else
    echo "$(date -u --rfc-3339=seconds) - Use both 'compute_cc_type'/'control_plane_cc_type' & 'default_machine_platform_cc_type'..."
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
platform:
  gcp:
    defaultMachinePlatform:
      confidentialCompute: ${default_machine_platform_cc_type}
      onHostMaintenance: ${on_host_maintenance}
EOF
  fi
  yq-go m -x -i "${install_dir}/install-config.yaml" "${patch}"
  echo "$(date -u --rfc-3339=seconds) - DEBUG 'yq-go r ${install_dir}/install-config.yaml platform'"
  yq-go r "${install_dir}/install-config.yaml" platform
  echo "$(date -u --rfc-3339=seconds) - DEBUG 'yq-go r ${install_dir}/install-config.yaml compute'"
  yq-go r "${install_dir}/install-config.yaml" compute
  echo "$(date -u --rfc-3339=seconds) - DEBUG 'yq-go r ${install_dir}/install-config.yaml controlPlane'"
  yq-go r "${install_dir}/install-config.yaml" controlPlane

  result=0
  cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"
  echo "$(date -u --rfc-3339=seconds) - INFO '${INSTALLER_BINARY} create manifests --dir ${install_dir}'"
  ${INSTALLER_BINARY} create manifests --dir ${install_dir} &> ${tmp_output} || result=1
  cat "${tmp_output}"

  if ! "${success_flag}"; then
    compose_expected_err_msg "${install_dir}/install-config.yaml.bak"    
    echo "$(date -u --rfc-3339=seconds) - Scenario ${testing_scenario_num}: the expected error messages are '${expected_err_msg}'"

    if ! grep -qF "${expected_err_msg}" "${tmp_output}"; then
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
