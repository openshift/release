#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'post_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"


echo "TEST_OBJECT: $TEST_OBJECT"
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

  echo "Copying kubeconfig and metadata.json to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"

  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "Copying install log and removing REDACTED info from log..."
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
  update_result "AMI" "${AMI_RESULT}"
  update_result "Install" "${INSTALL_RESULT}"
  update_result "CreatedDate" "${CREATED_DATE}"
  update_result "Job" "$(echo "${JOB_SPEC}" | jq -r '.job')"
  update_result "BuildID" "$(echo "${JOB_SPEC}" | jq -r '.buildid')"
  update_result "RowUpdated" "$(current_date)"

  echo "RESULT:"
  jq -r . "${OUT_RESULT}"

  # save JOB_SPEC to ARTIFACT_DIR for debugging
  echo "${JOB_SPEC}" | jq -r . > ${ARTIFACT_DIR}/JOB_SPEC.json

}

# creating cluster

SSH_PUB_KEY=$(< "${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(< "${CLUSTER_PROFILE_DIR}/pull-secret")

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

echo "Creating cluster in region ${REGION}:"
echo "ARCH: $ARCH"
echo "CONTROL_PLANE_INSTANCE*: $CONTROL_PLANE_INSTANCE_TYPE $CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
echo "COMPUTE_INSTANCE*: $COMPUTE_INSTANCE_TYPE $COMPUTE_INSTANCE_TYPE_FAMILY"

AMI_RESULT=""
INSTALL_RESULT=""
CREATED_DATE="$(current_date)"

function create_install_config() {
  local cluster_name=$1
  local install_dir=$2

  local config
  config=${install_dir}/install-config.yaml

  cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
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
# Pre-checks
# ---------------------------------------

echo "--- Check AMI ---"

if [ "$ARCH" == "amd64" ]; then
  ami_arch="x86_64"
elif [ "$ARCH" == "arm64" ]; then
  ami_arch="aarch64"
fi

set +e
amiid=$(openshift-install coreos print-stream-json | jq -r --arg a "$ami_arch" --arg r "$REGION" '.architectures[$a].images.aws.regions[$r].image')
set -e

echo "AMI architecture: ${ami_arch}, region: ${REGION}"

if is_empty "$amiid"; then
  AMI_RESULT="FAIL"
else
  AMI_RESULT="PASS"
fi

# ---------------------------------------
# Create install-config
# ---------------------------------------

echo "--- Create install-config ---"

create_install_config "${CLUSTER_NAME}" "${INSTALL_DIR}"
CONFIG="${INSTALL_DIR}"/install-config.yaml

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred

ZONES_JSON=/tmp/zones.json
aws --region "$REGION" ec2 describe-availability-zones --filters Name=opt-in-status,Values=opted-in,opt-in-not-required > ${ZONES_JSON}

# Patch region
export REGION
yq-v4 eval -i '.platform.aws.region = env(REGION)' "${CONFIG}"

# Patch ARCH
if [ "${ARCH}" == "" ]; then
  yq-v4 eval -i '.controlPlane.architecture = "amd64"' "${CONFIG}"
  yq-v4 eval -i '.controlPlane.architecture = "amd64"' "${CONFIG}"
else
  export ARCH
  yq-v4 eval -i '.controlPlane.architecture = env(ARCH)' "${CONFIG}"
  yq-v4 eval -i '.controlPlane.architecture = env(ARCH)' "${CONFIG}"
fi

# Patch instance type
if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
  export CONTROL_PLANE_INSTANCE_TYPE
  yq-v4 eval -i '.controlPlane.platform.aws.type = env(CONTROL_PLANE_INSTANCE_TYPE)' "${CONFIG}"
fi
if [[ ${COMPUTE_INSTANCE_TYPE} != "" ]]; then
  export COMPUTE_INSTANCE_TYPE
  yq-v4 eval -i '.compute[0].platform.aws.type = env(COMPUTE_INSTANCE_TYPE)' "${CONFIG}"
fi

# Patch AZ, only use one AZ to reduce EIP usage
if [ "$TEST_OBJECT" == "InstanceTypes" ];  then
  # check the instance type offering
  
  t1=$(mktemp)
  t2=$(mktemp)
  aws --region "$REGION" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="$CONTROL_PLANE_INSTANCE_TYPE" --query 'InstanceTypeOfferings[*].Location' | jq -r '.[]' | sort > "$t1"
  aws --region "$REGION" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="$COMPUTE_INSTANCE_TYPE" --query 'InstanceTypeOfferings[*].Location' | jq -r '.[]' | sort > "$t2"
  ZONE_NAME=$(comm -12 "$t1" "$t2" | head -n 1)
  if [ "$ZONE_NAME" == "" ]; then
    echo "ERROR: Can not find an Availability Zone that provides both $CONTROL_PLANE_INSTANCE_TYPE and $COMPUTE_INSTANCE_TYPE"
    exit 1
  fi
else
  # select the first one
  ZONE_NAME=$(jq -r '[.AvailabilityZones[] | select(.ZoneType=="availability-zone")] | .[0].ZoneName' "${ZONES_JSON}")
fi

if [ "${TEST_OBJECT}" != "LocalZones" ] && [ "${TEST_OBJECT}" != "WavelengthZones" ]; then
  export ZONE_NAME
  yq-v4 eval -i '.controlPlane.platform.aws.zones += [env(ZONE_NAME)]' "${CONFIG}"
  yq-v4 eval -i '.compute[0].platform.aws.zones += [env(ZONE_NAME)]' "${CONFIG}"
fi

# Patch Edge nodes
if [ "${TEST_OBJECT}" == "LocalZones" ] || [ "${TEST_OBJECT}" == "WavelengthZones" ]; then

  # patch edge node
  EDGE_ZONES_JSON=/tmp/edge_zones.json

  if [ "$TEST_OBJECT" == "WavelengthZones" ]; then
    ZONE_TYPE="wavelength-zone"
  fi

  if [ "$TEST_OBJECT" == "LocalZones" ]; then
    ZONE_TYPE="local-zone"
  fi

  jq -r --arg t "$ZONE_TYPE" '[.AvailabilityZones[] | select(.ZoneType==$t)]' "${ZONES_JSON}" > "${EDGE_ZONES_JSON}"

  EDGE_ZONE_COUNT=$(jq -r '. | length' ${EDGE_ZONES_JSON})
  EDGE_ZONE_NAMES=$(jq -r '.[].ZoneName' ${EDGE_ZONES_JSON})

  if [ "${ARCH}" == "" ]; then
    yq-v4 eval -i '.compute[1].architecture = "amd64"' "${CONFIG}"
  else
    export ARCH
    yq-v4 eval -i '.compute[1].architecture = env(ARCH)' "${CONFIG}"
  fi

  yq-v4 eval -i '.compute[1].hyperthreading = "Enabled"' "${CONFIG}"
  yq-v4 eval -i '.compute[1].name = "edge"' "${CONFIG}"
  export EDGE_ZONE_COUNT
  yq-v4 eval -i '.compute[1].replicas = env(EDGE_ZONE_COUNT)' "${CONFIG}"
  for edge_zone in ${EDGE_ZONE_NAMES}; do
    export edge_zone
    yq-v4 eval -i '.compute[1].platform.aws.zones += [env(edge_zone)]' "${CONFIG}"
    unset edge_zone
  done
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"

# ---------------------------------------

echo "--- Create manifests ---"

set +e
openshift-install create manifests --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to create manifests. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created manifests."
fi

# ---------------------------------------

echo "--- Create ignition configs ---"

set +e
openshift-install create ignition-configs --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to ignition configs. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created ignition configs."
fi

# ---------------------------------------

echo "--- Create cluster ---"

set +e
openshift-install create cluster --dir ${INSTALL_DIR} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
install_ret="$?"
set -e

if [ $install_ret -ne 0 ]; then
  echo "Failed to create clusters. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created cluster."
  INSTALL_RESULT="PASS"
fi
ret=$((ret + install_ret))

echo "ret: $ret"
exit $ret
