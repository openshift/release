#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# -----------------------------------------
# OCP-84040 - [IPI-on-GCP] install a cluster into GCP shared VPC with conflicting DNS private zone in separate project	
# -----------------------------------------

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"; eval "${cleanup_script}"' EXIT TERM


if [[ -f "${CLUSTER_PROFILE_DIR}/openshift_gcp_dns_project" ]]; then
  PRIVATE_ZONE_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_dns_project)"
else
  echo "Failed to find out PRIVATE_ZONE_PROJECT, abort." && exit 1
fi

export INSTALLER_BINARY="openshift-install"
${INSTALLER_BINARY} version

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GOOGLE_CLOUD_KEYFILE_JSON})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
REGION=${LEASED_RESOURCE}

SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
HOST_PROJECT=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_COMPUTE_SUBNET=$(jq -r '.computeSubnet' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_CONTROL_SUBNET=$(jq -r '.controlSubnet' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
NETWORK=$(basename ${HOST_PROJECT_NETWORK})
CONTROL_SUBNET=$(basename ${HOST_PROJECT_CONTROL_SUBNET})
COMPUTE_SUBNET=$(basename ${HOST_PROJECT_COMPUTE_SUBNET})

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
  local -r cluster_name=$1; shift
  local -r dns_private_zone_name=$1; shift
  local -r dns_private_zone_project=$1; shift
  local -r install_dir=$1

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
credentialsMode: Passthrough
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
    networkProjectID: ${HOST_PROJECT}
    network: ${NETWORK}
    controlPlaneSubnet: ${CONTROL_SUBNET}
    computeSubnet: ${COMPUTE_SUBNET}
    dns:
      privateZone: 
        name: ${dns_private_zone_name}
        projectID: ${dns_private_zone_project}
publish: External
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
}

function run_command() {
  local CMD="$1"
  echo "Running command: ${CMD}"
  eval "${CMD}"
}

## main
result=0
cleanup_script=$(mktemp); chmod +x "${cleanup_script}"
tmp_output=$(mktemp)

echo "$(date -u --rfc-3339=seconds) - Scenario A: a DNS private zone of different name, but with matching dns name and network is present"
cluster_name="${CLUSTER_NAME}-$RANDOM"
install_dir="/tmp/${cluster_name}"
mkdir -p "${install_dir}" 2>/dev/null

expected_zone_name="test-$RANDOM-priv-zone"
create_install_config "${cluster_name}" "${expected_zone_name}" "${PRIVATE_ZONE_PROJECT}" "${install_dir}"

wrong_zone_name="test-$RANDOM-private-zone"
echo "$(date -u --rfc-3339=seconds) - Scenario A: expected_zone_name '${expected_zone_name}', wrong_zone_name '${wrong_zone_name}'"
expected_err_msg="failed to create install config: platform.gcp.dns.privateZone.name: Invalid value: \"${expected_zone_name}\": found existing private zone ${wrong_zone_name} in project ${PRIVATE_ZONE_PROJECT} with DNS name ${cluster_name}.${BASE_DOMAIN}"

cmd="gcloud --project ${PRIVATE_ZONE_PROJECT} dns managed-zones create ${wrong_zone_name} --dns-name ${cluster_name}.${BASE_DOMAIN}. --visibility=private --networks ${HOST_PROJECT_NETWORK} --description \"private zone of OCP cluster '${cluster_name}'\""
run_command "${cmd}"

cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"
echo "$(date -u --rfc-3339=seconds) - INFO '${INSTALLER_BINARY} create manifests --dir ${install_dir}'"
${INSTALLER_BINARY} create manifests --dir ${install_dir} &> ${tmp_output} || true
cat "${tmp_output}"
if ! grep -qF "${expected_err_msg}" "${tmp_output}"; then
  echo "$(date -u --rfc-3339=seconds) - Scenario A: FAILED, the expected error messages are not found in '.openshift_install.log'."
  result=$((result+1))
else
  echo "$(date -u --rfc-3339=seconds) - Scenario A: PASSED, found the expected error messages in '.openshift_install.log'."
fi
save_artifacts "${install_dir}" "scenario-a"

cmd="gcloud --project ${PRIVATE_ZONE_PROJECT} dns managed-zones delete -q ${wrong_zone_name}"
#run_command "${cmd}"
echo "${cmd} || true" >> "${cleanup_script}"
rm -fr "${install_dir}"

echo "$(date -u --rfc-3339=seconds) - Scenario B: a DNS private zone of matching name and network, but different dns name is present"
cluster_name="${CLUSTER_NAME}-$RANDOM"
install_dir="/tmp/${cluster_name}"
mkdir -p "${install_dir}" 2>/dev/null

expected_zone_name="test-$RANDOM-priv-zone"
create_install_config "${cluster_name}" "${expected_zone_name}" "${PRIVATE_ZONE_PROJECT}" "${install_dir}"

echo "$(date -u --rfc-3339=seconds) - Scenario B: expected_zone_name '${expected_zone_name}'"
expected_err_msg="failed to create install config: baseDomain: Invalid value: \"${BASE_DOMAIN}\": failed to find matching DNS zone for ${expected_zone_name} with DNS name ${cluster_name}.${BASE_DOMAIN}"

cmd="gcloud --project ${PRIVATE_ZONE_PROJECT} dns managed-zones create ${expected_zone_name} --dns-name ${cluster_name}.dns.${BASE_DOMAIN}. --visibility=private --networks ${HOST_PROJECT_NETWORK} --description \"private zone of OCP cluster '${cluster_name}'\""
run_command "${cmd}"

cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"
echo "$(date -u --rfc-3339=seconds) - INFO '${INSTALLER_BINARY} create manifests --dir ${install_dir}'"
${INSTALLER_BINARY} create manifests --dir ${install_dir} &> ${tmp_output} || true
cat "${tmp_output}"
if ! grep -qF "${expected_err_msg}" "${tmp_output}"; then
  echo "$(date -u --rfc-3339=seconds) - Scenario B: FAILED, the expected error messages are not found in '.openshift_install.log'."
  result=$((result+1))
else
  echo "$(date -u --rfc-3339=seconds) - Scenario B: PASSED, found the expected error messages in '.openshift_install.log'."
fi
save_artifacts "${install_dir}" "scenario-b"

cmd="gcloud --project ${PRIVATE_ZONE_PROJECT} dns managed-zones delete -q ${expected_zone_name}"
#run_command "${cmd}"
echo "${cmd} || true" >> "${cleanup_script}"
rm -fr "${install_dir}"

echo "Exit code: '$result'"
exit $result
