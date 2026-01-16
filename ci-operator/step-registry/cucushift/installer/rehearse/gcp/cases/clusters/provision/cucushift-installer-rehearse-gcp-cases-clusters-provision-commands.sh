#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'post_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"


echo "$(date -u --rfc-3339=seconds) - TEST_OBJECT: $TEST_OBJECT"
OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json
OUT_RESULT=${SHARED_DIR}/result.json
echo '{}' > "$OUT_RESULT"

IC_COMPUTE_NODE_COUNT=2
IC_CONTROL_PLANE_NODE_COUNT=3

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

if [ ! -f "${OUT_SELECT}" ]; then
  echo "ERROR: Not found OUT_SELECT file."
  exit 1
fi

if [ ! -f "${OUT_SELECT_DICT}" ]; then
  echo "ERROR: Not found OUT_SELECT_DICT file."
  exit 1
fi

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function post_actions() {
  set +e

  current_time=$(date +%s)

  echo "$(date -u --rfc-3339=seconds) - Copying kubeconfig and metadata.json to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"

  echo "$(date -u --rfc-3339=seconds) - Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "$(date -u --rfc-3339=seconds) - Copying install log and removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # Writing result
  # "Bucket": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.bucket')",
  # "JobUrlPrefix": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.job_url_prefix')",
  
  update_result "Region" "${REGION}"
  update_result "CPType" "${CONTROL_PLANE_INSTANCE_TYPE}"
  update_result "CPamily" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
  update_result "CType" "${COMPUTE_INSTANCE_TYPE}"
  update_result "CFamily" "${COMPUTE_INSTANCE_TYPE_FAMILY}"
  update_result "Arch" "${ARCH}"
  update_result "Install" "${INSTALL_RESULT}"
  update_result "CreatedDate" "${CREATED_DATE}"
  update_result "Job" "$(echo "${JOB_SPEC}" | jq -r '.job')"
  update_result "BuildID" "$(echo "${JOB_SPEC}" | jq -r '.buildid')"
  update_result "RowUpdated" "$(current_date)"

  echo "$(date -u --rfc-3339=seconds) - RESULT:"
  jq -r . "${OUT_RESULT}"

  # save JOB_SPEC to ARTIFACT_DIR for debugging
  echo "${JOB_SPEC}" | jq -r . > ${ARTIFACT_DIR}/JOB_SPEC.json

}

# creating cluster

SSH_PUB_KEY=$(< "${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(< "${CLUSTER_PROFILE_DIR}/pull-secret")

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi
REGION="$(jq -r '.Region' "${OUT_SELECT_DICT}")"
ARCH="$(jq -r '.Arch' "${OUT_SELECT_DICT}")"

CONTROL_PLANE_INSTANCE_TYPE="$(jq -r '.CPType' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_FAMILY="$(jq -r '.CPFamily' "${OUT_SELECT_DICT}")"

COMPUTE_INSTANCE_TYPE="$(jq -r '.CType' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_FAMILY="$(jq -r '.CFamily' "${OUT_SELECT_DICT}")"

if is_empty "$ARCH"; then
  # Default ARCH is determined by each plarform.
  # For most of cased, default is arm.
  # For the resgions which do not support arm64, then set amd64
  ARCH="arm64"
fi

echo "$(date -u --rfc-3339=seconds) - Creating cluster in region ${REGION}:"
echo "$(date -u --rfc-3339=seconds) - ARCH: $ARCH"
echo "$(date -u --rfc-3339=seconds) - CONTROL_PLANE_INSTANCE*: $CONTROL_PLANE_INSTANCE_TYPE $CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
echo "$(date -u --rfc-3339=seconds) - COMPUTE_INSTANCE*: $COMPUTE_INSTANCE_TYPE $COMPUTE_INSTANCE_TYPE_FAMILY"

INSTALL_RESULT=""
CREATED_DATE="$(current_date)"

function create_install_config() {
  local cluster_name=$1
  local install_dir=$2

  local config
  config=${install_dir}/install-config.yaml

  cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${GCP_BASE_DOMAIN}
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: ${IC_CONTROL_PLANE_NODE_COUNT}
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
platform: {}
publish: External
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
}

ret=0

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
INSTALL_DIR=/tmp/install_dir
mkdir -p ${INSTALL_DIR}

# ---------------------------------------
# Print openshift-install version
# ---------------------------------------

openshift-install version

# ---------------------------------------
# Create install-config
# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create install-config"

create_install_config "${CLUSTER_NAME}" "${INSTALL_DIR}"
CONFIG="${INSTALL_DIR}"/install-config.yaml

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
gcloud config set project "${GOOGLE_PROJECT_ID}"

echo "$(date -u --rfc-3339=seconds) - Patch region and projectID"
export REGION
yq-v4 eval -i '.platform.gcp.region = env(REGION)' "${CONFIG}"
export GOOGLE_PROJECT_ID
yq-v4 eval -i '.platform.gcp.projectID = env(GOOGLE_PROJECT_ID)' "${CONFIG}"

echo "$(date -u --rfc-3339=seconds) - Patch instance types and osDisk.diskType"
if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
  export CONTROL_PLANE_INSTANCE_TYPE
  yq-v4 eval -i '.controlPlane.platform.gcp.type = env(CONTROL_PLANE_INSTANCE_TYPE)' "${CONFIG}"

  # Patch OS disk type for N4 / C4 / C4A machine series
  if [[ ${CONTROL_PLANE_INSTANCE_TYPE_FAMILY} == N4 ]] || \
  [[ ${CONTROL_PLANE_INSTANCE_TYPE_FAMILY} == C4 ]] || \
  [[ ${CONTROL_PLANE_INSTANCE_TYPE_FAMILY} == C4A ]]; then
    export OS_DISK_TYPE="hyperdisk-balanced"
    yq-v4 eval -i '.controlPlane.platform.gcp.osDisk.diskType = env(OS_DISK_TYPE)' "${CONFIG}"
  fi
fi
if [[ ${COMPUTE_INSTANCE_TYPE} != "" ]]; then
  export COMPUTE_INSTANCE_TYPE
  yq-v4 eval -i '.compute[0].platform.gcp.type = env(COMPUTE_INSTANCE_TYPE)' "${CONFIG}"

  # Patch OS disk type for N4 / C4 / C4A machine series
  if [[ ${COMPUTE_INSTANCE_TYPE_FAMILY} == N4 ]] || \
  [[ ${COMPUTE_INSTANCE_TYPE_FAMILY} == C4 ]] || \
  [[ ${COMPUTE_INSTANCE_TYPE_FAMILY} == C4A ]]; then
    export OS_DISK_TYPE="hyperdisk-balanced"
    yq-v4 eval -i '.compute[0].platform.gcp.osDisk.diskType = env(OS_DISK_TYPE)' "${CONFIG}"
  fi
fi

echo "$(date -u --rfc-3339=seconds) - Patch availability zones"
found_az_for_control_plane=false
found_az_for_comute=false
readarray -t availability_zones < <(gcloud compute regions describe "${REGION}" | grep 'https://www.googleapis.com/compute/v1/projects/.*/zones/' | sed 's#- https://www.googleapis.com/compute/v1/projects/[_a-zA-Z0-9-]*/zones/##g')
for ZONE_NAME in "${availability_zones[@]}"
do
  if gcloud compute machine-types describe "${CONTROL_PLANE_INSTANCE_TYPE}" --zone "${ZONE_NAME}"; then
    export ZONE_NAME
    yq-v4 eval -i '.controlPlane.platform.gcp.zones += [env(ZONE_NAME)]' "${CONFIG}"
    found_az_for_control_plane=true
  else
    echo "Skip zone '${ZONE_NAME}' for machine type '${CONTROL_PLANE_INSTANCE_TYPE}'."
  fi
  if gcloud compute machine-types describe "${COMPUTE_INSTANCE_TYPE}" --zone "${ZONE_NAME}"; then
    export ZONE_NAME
    yq-v4 eval -i '.compute[0].platform.gcp.zones += [env(ZONE_NAME)]' "${CONFIG}"
    found_az_for_comute=true
  else
    echo "Skip zone '${ZONE_NAME}' for machine type '${COMPUTE_INSTANCE_TYPE}'."
  fi
done
if ! (${found_az_for_control_plane} && ${found_az_for_comute}); then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find availability zone for control-plane and/or compute."
  exit 1
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform, "baseDomain": .baseDomain})' "${CONFIG}"

cp "${CONFIG}" "${SHARED_DIR}"/install-config.yaml

# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create manifests"

set +e
openshift-install create manifests --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to create manifests. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created manifests."
fi

# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create ignition configs"

set +e
openshift-install create ignition-configs --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to ignition configs. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created ignition configs."
fi

# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create cluster"

set +e
openshift-install create cluster --dir ${INSTALL_DIR} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
install_ret="$?"
set -e

if [ $install_ret -ne 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to create clusters ($install_ret)"
  INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created cluster."
  INSTALL_RESULT="PASS"
fi
ret=$((ret + install_ret))

echo "Exit code: $ret"
exit $ret
