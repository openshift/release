#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# -----------------------------------------
# OCP-76346 - [IPI-on-GCP] Validate instance type and OS disk type	
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

# instance_type: supported_osdisk_types,unsupported_osdisk_types
declare -A instance_type_osdisk_type_dict=(
  [c4d-standard-8]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [c4-standard-8]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [c4a-standard-4]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [c3-highcpu-192-metal]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [c3-standard-8]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [c3d-standard-8]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [n4-standard-4]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [n4a-standard-4]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [n4d-standard-4]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [n4-custom-36-294912]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [n2-standard-4]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [n2d-standard-4]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [n2-custom-32-34816]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [custom-4-16384]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [n1-standard-4]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [e2-standard-8]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [t2a-standard-4]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [t2d-standard-8]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [z3-highmem-14-standardlssd]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [h4d-standard-192]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [h3-standard-88]="pd-balanced hyperdisk-balanced,pd-standard pd-ssd"
  [c2-standard-8]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [c2d-standard-8]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [x4-480-6t-metal]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [m4-hypermem-16]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [m3-ultramem-32]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [m2-ultramem-208]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [m1-ultramem-40]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [a4x-highgpu-4g]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [a4-highgpu-8g]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [a3-ultragpu-8g]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [a3-megagpu-8g]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [a3-highgpu-8g]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [a3-edgegpu-8g]="pd-ssd pd-balanced hyperdisk-balanced,pd-standard"
  [a2-ultragpu-1g]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [a2-highgpu-1g]="pd-standard pd-ssd pd-balanced,hyperdisk-balanced"
  [g4-standard-48]="hyperdisk-balanced,pd-standard pd-ssd pd-balanced"
  [g2-standard-4]="pd-ssd pd-balanced,pd-standard hyperdisk-balanced"
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
  local instance_type1 unsupported_osdisk_types1
  # compute
  local instance_type2 unsupported_osdisk_types2

  instance_type1=$(yq-go r "${install_config_file}" controlPlane.platform.gcp.type)
  if [[ -z "${instance_type1}" ]]; then
    instance_type1=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.type)
  fi

  instance_type2=$(yq-go r "${install_config_file}" compute[0].platform.gcp.type)
  if [[ -z "${instance_type2}" ]]; then
    instance_type2=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.type)
  fi

  osdisk_type1=$(yq-go r "${install_config_file}" controlPlane.platform.gcp.osDisk.diskType)
  if [[ -z "${osdisk_type1}" ]]; then
    osdisk_type1=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.osDisk.diskType)
  fi

  osdisk_type2=$(yq-go r "${install_config_file}" compute[0].platform.gcp.osDisk.diskType)
  if [[ -z "${osdisk_type2}" ]]; then
    osdisk_type2=$(yq-go r "${install_config_file}" platform.gcp.defaultMachinePlatform.osDisk.diskType)
  fi

  supported_osdisk_types1=$(echo "${instance_type_osdisk_type_dict[${instance_type1}]}" | cut -d, -f1)
  supported_osdisk_types2=$(echo "${instance_type_osdisk_type_dict[${instance_type2}]}" | cut -d, -f1)
  unsupported_osdisk_types1=$(echo "${instance_type_osdisk_type_dict[${instance_type1}]}" | cut -d, -f2)
  unsupported_osdisk_types2=$(echo "${instance_type_osdisk_type_dict[${instance_type2}]}" | cut -d, -f2)

  expected_err_msg=""
  if echo "${unsupported_osdisk_types1}" | grep -qw "${osdisk_type1}"; then
    expected_err_msg="controlPlane.platform.gcp.diskType: Invalid value: \"${osdisk_type1}\": ${instance_type1} instance requires one of the following disk types: [${supported_osdisk_types1}]"
  fi

  if echo "${unsupported_osdisk_types2}" | grep -qw "${osdisk_type2}"; then
    if [[ "${expected_err_msg}" != "" ]]; then
      expected_err_msg="${expected_err_msg}, "
    fi
    expected_err_msg="${expected_err_msg}compute[0].platform.gcp.diskType: Invalid value: \"${osdisk_type2}\": ${instance_type2} instance requires one of the following disk types: [${supported_osdisk_types2}]"
  fi
}

function create_manifests()
{
  local -r instance_type="$1"
  local -r osdisk_type="$2"
  local -r testing_scenario_num="$3"
  local -r success_flag="$4"
  local cluster_name install_dir compute_osdisk_type control_plane_osdisk_type result tmp_output

  tmp_output=$(mktemp)
  cluster_name="${CLUSTER_PREFIX}${testing_scenario_num}"
  install_dir="/tmp/${cluster_name}"
  mkdir -p "${install_dir}" 2>/dev/null
  create_install_config "${cluster_name}" "${install_dir}"

  compute_osdisk_type="${osdisk_type}"
  control_plane_osdisk_type="${osdisk_type}"
  if [[ "${control_plane_osdisk_type}" == pd-standard ]]; then
    control_plane_osdisk_type="pd-ssd"
  fi

  arch="amd64"
  if [[ "${instance_type}" =~ t2a- ]] || [[ "${instance_type}" =~ c4a- ]] || [[ "${instance_type}" =~ n4a- ]]; then
    arch="arm64"
  fi

  cat > "${patch}" << EOF
compute:
- name: worker
  architecture: ${arch}
  platform:
    gcp:
      type: ${instance_type}
      osDisk:
        diskType: ${compute_osdisk_type}
controlPlane:
  name: master
  architecture: ${arch}
  platform:
    gcp:
      type: ${instance_type}
      osDisk:
        diskType: ${control_plane_osdisk_type}
platform:
  gcp:
    defaultMachinePlatform: 
      onHostMaintenance: Terminate
EOF
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
for instance_type in "${!instance_type_osdisk_type_dict[@]}"
do
  supported_osdisk_types=$(echo "${instance_type_osdisk_type_dict[${instance_type}]}" | cut -d, -f1)
  unsupported_osdisk_types=$(echo "${instance_type_osdisk_type_dict[${instance_type}]}" | cut -d, -f2)

  if [[ "${unsupported_osdisk_types}" != "" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + unsupported OS disk types..."
    IFS=' ' read -r -a osdisk_types_array <<< "${unsupported_osdisk_types}"
    for osdisk_type in "${osdisk_types_array[@]}"
    do
      num=$((num+1))
      create_manifests "${instance_type}" "${osdisk_type}" "${num}" false
    done
  fi

  if [[ "${supported_osdisk_types}" != "" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Scenario ${num}: Testing with instance type '${instance_type}' + supported OS disk types..."
    IFS=' ' read -r -a osdisk_types_array <<< "${supported_osdisk_types}"
    for osdisk_type in "${osdisk_types_array[@]}"
    do
      num=$((num+1))
      create_manifests "${instance_type}" "${osdisk_type}" "${num}" true
    done
  fi
done

exit $ret
