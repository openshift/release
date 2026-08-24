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

REGION=""
CONTROL_PLANE_INSTANCE_TYPE=""
CONTROL_PLANE_INSTANCE_TYPE_FAMILY=""
CONTROL_PLANE_ARCH=""
CONTROL_PLANE_ZONES=""
COMPUTE_INSTANCE_TYPE=""
COMPUTE_INSTANCE_TYPE_FAMILY=""
COMPUTE_ARCH=""
COMPUTE_ZONES=""
INSTALL_RESULT=""
CREATED_DATE=""

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
  cat <<< "$(jq --arg k "$k" --arg v "$v" '. + {($k): $v}' "$OUT_RESULT")" > "$OUT_RESULT"
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
  update_result "CPFamily" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
  update_result "CPArch" "${CONTROL_PLANE_ARCH}"
  update_result "CPZones" "${CONTROL_PLANE_ZONES}"
  update_result "CType" "${COMPUTE_INSTANCE_TYPE}"
  update_result "CFamily" "${COMPUTE_INSTANCE_TYPE_FAMILY}"
  update_result "CArch" "${COMPUTE_ARCH}"
  update_result "CZones" "${COMPUTE_ZONES}"
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

CONTROL_PLANE_INSTANCE_TYPE="$(jq -r '.CPType' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_FAMILY="$(jq -r '.CPFamily' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_ARCH="$(jq -r '.CPArch' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_ZONES="$(jq -r '.CPZones' "${OUT_SELECT_DICT}")"

COMPUTE_INSTANCE_TYPE="$(jq -r '.CType' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_FAMILY="$(jq -r '.CFamily' "${OUT_SELECT_DICT}")"
COMPUTE_ARCH="$(jq -r '.CArch' "${OUT_SELECT_DICT}")"
COMPUTE_ZONES="$(jq -r '.CZones' "${OUT_SELECT_DICT}")"

if [[ -n "${COMPUTE_ZONES}" ]] && [[ "${COMPUTE_ZONES}" != "null" ]]; then
  FIRST_COMPUTE_ZONE=$(echo "${COMPUTE_ZONES}" | jq -r '.[0]' 2>/dev/null || echo "${COMPUTE_ZONES}" | awk -F',' '{print $1}')
  FIRST_COMPUTE_ZONE="${FIRST_COMPUTE_ZONE//[\"\[\]]/}"
else
  FIRST_COMPUTE_ZONE=""
fi

if is_empty "${CONTROL_PLANE_ARCH}"; then
  # Default ARCH is determined by each platform.
  # For GCP, if not explicitly requested, we assume amd64 is safe default, 
  # but some arm jobs expect arm64 if unspecified. We'll default to amd64 
  # unless overridden dynamically later.
  CONTROL_PLANE_ARCH="amd64"
fi

if is_empty "${COMPUTE_ARCH}"; then
  COMPUTE_ARCH="amd64"
fi

echo "$(date -u --rfc-3339=seconds) - Creating cluster in region ${REGION}:"
echo "$(date -u --rfc-3339=seconds) - CONTROL_PLANE_ARCH: $CONTROL_PLANE_ARCH"
echo "$(date -u --rfc-3339=seconds) - COMPUTE_ARCH: $COMPUTE_ARCH"
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
- architecture: ${COMPUTE_ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: ${CONTROL_PLANE_ARCH}
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

function patch_region_project() {
  local config=$1
  echo "$(date -u --rfc-3339=seconds) - Patch region and projectID"
  export REGION
  yq-v4 eval -i '.platform.gcp.region = env(REGION)' "${config}"
  export GOOGLE_PROJECT_ID
  yq-v4 eval -i '.platform.gcp.projectID = env(GOOGLE_PROJECT_ID)' "${config}"
}

function patch_instance_type_and_os_disk() {
  local config=$1
  local role=$2
  local machine_type=$3
  local family=$4

  echo "$(date -u --rfc-3339=seconds) - Patch instance type and osDisk.diskType for ${role}"
  
  local yq_path=""
  if [[ "${role}" == "control-plane" ]]; then
    yq_path=".controlPlane.platform.gcp"
  else
    yq_path=".compute[0].platform.gcp"
  fi

  if [[ -n "${machine_type}" ]]; then
    export machine_type
    yq-v4 eval -i "${yq_path}.type = env(machine_type)" "${config}"

    case ${family} in
      Z3)
        echo "$(date -u --rfc-3339=seconds) - Patching onHostMaintenance to Migrate for Z3 machine series"
        export ON_HOST_MAINTENANCE="Migrate"
        yq-v4 eval -i "${yq_path}.onHostMaintenance = env(ON_HOST_MAINTENANCE)" "${config}"
        ;;
      X4)
        echo "$(date -u --rfc-3339=seconds) - Patching onHostMaintenance to Terminate for X4 machine series"
        export ON_HOST_MAINTENANCE="Terminate"
        yq-v4 eval -i "${yq_path}.onHostMaintenance = env(ON_HOST_MAINTENANCE)" "${config}"
        ;;
    esac

    # Patch OS disk type for machine series only supporting hyperdisk-balanced
    case ${family} in
      C4D|C4|C4A|N4|N4A|N4D|H4D|H3|X4|M4|A4X|A4|G4|A3ULTRA)
        export OS_DISK_TYPE="hyperdisk-balanced"
        yq-v4 eval -i "${yq_path}.osDisk.diskType = env(OS_DISK_TYPE)" "${config}"
        ;;
    esac
  fi
}

function patch_availability_zones() {
  local config=$1
  local role=$2
  local machine_type=$3
  local manual_zones=$4

  echo "$(date -u --rfc-3339=seconds) - Patch availability zones for ${role} using machine type ${machine_type}"
  
  local yq_path=""
  if [[ "${role}" == "control-plane" ]]; then
    yq_path=".controlPlane.platform.gcp.zones"
  else
    yq_path=".compute[0].platform.gcp.zones"
  fi

  local availability_zones=()
  if [[ -n "${manual_zones}" ]] && [[ "${manual_zones}" != "null" ]]; then
    readarray -t availability_zones < <(echo "${manual_zones}" | jq -r '.[]' 2>/dev/null || echo "${manual_zones}" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//')
  else
    readarray -t availability_zones < <(gcloud compute regions describe "${REGION}" | grep 'https://www.googleapis.com/compute/v1/projects/.*/zones/' | sed 's#- https://www.googleapis.com/compute/v1/projects/[_a-zA-Z0-9-]*/zones/##g')
  fi

  local found_az=false
  for ZONE_NAME in "${availability_zones[@]}"
  do
    if gcloud compute machine-types describe "${machine_type}" --zone "${ZONE_NAME}" >/dev/null 2>&1; then
      if [[ "${role}" == "worker" ]] && [[ -z "${FIRST_COMPUTE_ZONE}" ]]; then
        export FIRST_COMPUTE_ZONE="${ZONE_NAME}"
      fi
      export ZONE_NAME
      yq-v4 eval -i "${yq_path} += [env(ZONE_NAME)]" "${config}"
      found_az=true
    else
      echo "Skip zone '${ZONE_NAME}' for machine type '${machine_type}'."
    fi
  done

  if ! ${found_az}; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find availability zone for ${role} with machine type ${machine_type}."
    exit 1
  fi
}

function patch_worker_machineset() {
  local install_dir=$1
  local machine_type=$2
  local family=$3
  local zone=$4

  echo "$(date -u --rfc-3339=seconds) - Patching worker MachineSet for zone ${zone} with ${machine_type}"

  local target_ms=""
  # Search for the MachineSet that corresponds to the target zone
  for ms in "${install_dir}/openshift/99_openshift-cluster-api_worker-machineset-"*.yaml; do
    # Skip if glob didn't match any files
    [[ -e "$ms" ]] || continue
    
    ms_zone=$(yq-v4 eval '.spec.template.spec.providerSpec.value.zone' "$ms")
    if [[ "$ms_zone" == "$zone" ]]; then
      target_ms="$ms"
      break
    fi
  done
  
  if [[ -z "${target_ms}" ]]; then
    echo "ERROR: MachineSet for zone ${zone} not found after generating manifests."
    exit 1
  fi

  echo "$(date -u --rfc-3339=seconds) - Patching ${target_ms} to use ${machine_type} and 1 replica"
  export machine_type
  yq-v4 eval -i '.spec.template.spec.providerSpec.value.machineType = env(machine_type)' "${target_ms}"
  yq-v4 eval -i '.spec.replicas = 1' "${target_ms}"

  # Patch onHostMaintenance for machines with accelerators, and specific machine series
  local machine_info
  machine_info=$(gcloud compute machine-types describe "${machine_type}" --zone "${zone}" --format="json")
  local accelerators
  accelerators=$(echo "${machine_info}" | jq -r 'if has("accelerators") then (.accelerators | length) else 0 end')
  
  if [[ "${accelerators}" -gt 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Patching onHostMaintenance to Terminate for machine with accelerators"
    yq-v4 eval -i '.spec.template.spec.providerSpec.value.onHostMaintenance = "Terminate"' "${target_ms}"
  fi

  case ${family} in
    Z3)
      echo "$(date -u --rfc-3339=seconds) - Patching onHostMaintenance to Migrate for Z3 machine series"
      yq-v4 eval -i '.spec.template.spec.providerSpec.value.onHostMaintenance = "Migrate"' "${target_ms}"
      ;;
    X4)
      echo "$(date -u --rfc-3339=seconds) - Patching onHostMaintenance to Terminate for X4 machine series"
      yq-v4 eval -i '.spec.template.spec.providerSpec.value.onHostMaintenance = "Terminate"' "${target_ms}"
      ;;
  esac

  # Patch OS disk type if needed
  case ${family} in
    C4D|C4|C4A|N4|N4A|N4D|H4D|H3|X4|M4|A4X|A4|G4|A3ULTRA)
      export OS_DISK_TYPE="hyperdisk-balanced"
      yq-v4 eval -i '.spec.template.spec.providerSpec.value.disks[0].type = env(OS_DISK_TYPE)' "${target_ms}"
      ;;
  esac

  if [[ "${machine_type}" == "a3-highgpu-1g" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Patching preemptible to true for a3-highgpu-1g"
    yq-v4 eval -i '.spec.template.spec.providerSpec.value.preemptible = true' "${target_ms}"
  fi

  echo "$(date -u --rfc-3339=seconds) - Debug: Patched providerSpec for ${target_ms}:"
  yq-v4 eval '.spec.template.spec.providerSpec.value' "${target_ms}"

  # Adjust other MachineSets to maintain IC_COMPUTE_NODE_COUNT total workers
  local current_total_workers=1
  for ms in $(ls "${install_dir}/openshift/99_openshift-cluster-api_worker-machineset-"*.yaml | sort); do
    if [[ "$(realpath "${ms}")" == "$(realpath "${target_ms}")" ]]; then
      continue
    fi
    if [[ ${current_total_workers} -lt ${IC_COMPUTE_NODE_COUNT} ]]; then
      echo "$(date -u --rfc-3339=seconds) - Setting replicas to 1 for ${ms} (default N2)"
      yq-v4 eval -i '.spec.replicas = 1' "${ms}"
      current_total_workers=$((current_total_workers + 1))
    else
      echo "$(date -u --rfc-3339=seconds) - Setting replicas to 0 for ${ms}"
      yq-v4 eval -i '.spec.replicas = 0' "${ms}"
    fi
  done
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

patch_region_project "${CONFIG}"

# Ensure FIRST_COMPUTE_ZONE is populated for machine inspection
if [[ -z "${FIRST_COMPUTE_ZONE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Dynamically finding a supported zone for ${COMPUTE_INSTANCE_TYPE}"
  readarray -t availability_zones < <(gcloud compute regions describe "${REGION}" | grep 'https://www.googleapis.com/compute/v1/projects/.*/zones/' | sed 's#- https://www.googleapis.com/compute/v1/projects/[_a-zA-Z0-9-]*/zones/##g')
  for ZONE_NAME in "${availability_zones[@]}"; do
    if gcloud compute machine-types describe "${COMPUTE_INSTANCE_TYPE}" --zone "${ZONE_NAME}" >/dev/null 2>&1; then
      export FIRST_COMPUTE_ZONE="${ZONE_NAME}"
      break
    fi
  done
  if [[ -z "${FIRST_COMPUTE_ZONE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find availability zone supporting ${COMPUTE_INSTANCE_TYPE}."
    exit 1
  fi
fi

# Determine if the machine is "High Resource"
echo "$(date -u --rfc-3339=seconds) - Inspecting machine type ${COMPUTE_INSTANCE_TYPE} in zone ${FIRST_COMPUTE_ZONE}"
MACHINE_INFO=$(gcloud compute machine-types describe "${COMPUTE_INSTANCE_TYPE}" --zone "${FIRST_COMPUTE_ZONE}" --format="json")
GUEST_CPUS=$(echo "${MACHINE_INFO}" | jq -r '.guestCpus // 0')
MEMORY_MB=$(echo "${MACHINE_INFO}" | jq -r '.memoryMb // 0')
ACCELERATORS=$(echo "${MACHINE_INFO}" | jq -r 'if has("accelerators") then (.accelerators | length) else 0 end')

IS_EXPENSIVE_MACHINE=false
# Criteria: much higher resources (>= 16 vCPUs and >= 64GB RAM), or having accelerators.
if [[ "${ACCELERATORS}" -gt 0 ]] || { [[ "${GUEST_CPUS}" -ge 16 ]] && [[ "${MEMORY_MB}" -ge 65536 ]]; }; then
    IS_EXPENSIVE_MACHINE=true
    echo "$(date -u --rfc-3339=seconds) - High-resource/accelerator machine detected (vCPUs=${GUEST_CPUS}, memoryMb=${MEMORY_MB}, accelerators=${ACCELERATORS}). Will use Scenario 1 (patch one worker)."
else
    echo "$(date -u --rfc-3339=seconds) - Standard machine detected. Will use Scenario 2 (direct install-config)."
fi

if [[ "${IS_EXPENSIVE_MACHINE}" == "true" ]]; then
    # Scenario 1: Use specified control-plane but default worker for initial config
    DEFAULT_COMPUTE_INSTANCE_TYPE="n2-standard-2"
    DEFAULT_COMPUTE_FAMILY="N2"
    if [[ "${COMPUTE_ARCH}" == "arm64" ]]; then
        DEFAULT_COMPUTE_INSTANCE_TYPE="t2a-standard-2"
        DEFAULT_COMPUTE_FAMILY="T2A"
    fi
    echo "$(date -u --rfc-3339=seconds) - Using specified control-plane (${CONTROL_PLANE_INSTANCE_TYPE}) and default worker (${DEFAULT_COMPUTE_INSTANCE_TYPE}) for initial config"
    patch_instance_type_and_os_disk "${CONFIG}" "control-plane" "${CONTROL_PLANE_INSTANCE_TYPE}" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
    patch_instance_type_and_os_disk "${CONFIG}" "worker" "${DEFAULT_COMPUTE_INSTANCE_TYPE}" "${DEFAULT_COMPUTE_FAMILY}"
    
    # Filter zones to ensure they support the specified control plane type and the default worker type
    patch_availability_zones "${CONFIG}" "control-plane" "${CONTROL_PLANE_INSTANCE_TYPE}" "${CONTROL_PLANE_ZONES}"
    patch_availability_zones "${CONFIG}" "worker" "${DEFAULT_COMPUTE_INSTANCE_TYPE}" "${COMPUTE_ZONES}"
else
    # Scenario 2: Use specified types directly
    patch_instance_type_and_os_disk "${CONFIG}" "control-plane" "${CONTROL_PLANE_INSTANCE_TYPE}" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
    patch_instance_type_and_os_disk "${CONFIG}" "worker" "${COMPUTE_INSTANCE_TYPE}" "${COMPUTE_INSTANCE_TYPE_FAMILY}"
    
    # Filter zones based directly on the specified types
    patch_availability_zones "${CONFIG}" "control-plane" "${CONTROL_PLANE_INSTANCE_TYPE}" "${CONTROL_PLANE_ZONES}"
    patch_availability_zones "${CONFIG}" "worker" "${COMPUTE_INSTANCE_TYPE}" "${COMPUTE_ZONES}"
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
  
  if [[ "${IS_EXPENSIVE_MACHINE}" == "true" ]]; then
    if [[ -n "${FIRST_COMPUTE_ZONE}" ]]; then
      patch_worker_machineset "${INSTALL_DIR}" "${COMPUTE_INSTANCE_TYPE}" "${COMPUTE_INSTANCE_TYPE_FAMILY}" "${FIRST_COMPUTE_ZONE}"
    else
      echo "ERROR: Could not determine a valid compute zone for patching."
      exit 1
    fi
  fi
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
