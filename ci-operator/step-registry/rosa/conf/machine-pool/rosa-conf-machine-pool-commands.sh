#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
HOSTED_CP=${HOSTED_CP:-false}
MP_MACHINE_TYPE=${MP_MACHINE_TYPE:-"m5.xlarge"}
MP_ENABLE_AUTOSCALING=${ENABLE_AUTOSCALING:-false}
USE_TUNING_CONFIG=${USE_TUNING_CONFIG:-false}
USE_SPOT_INSTANCES=${USE_SPOT_INSTANCES:-false}
SPOT_MAX_PRICE=${SPOT_MAX_PRICE:-"on-demand"}
LOCAL_ZONE=${LOCAL_ZONE:-false}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Switches
LABELS="prowci=true"
if [[ ! -z "$MP_LABELS" ]]; then
  LABELS="${LABELS},${MP_LABELS}"
fi

TAINTS="prowci=true:NoSchedule"
if [[ ! -z "$MP_TAINTS" ]]; then
  TAINTS="${MP_TAINTS}"
fi

MP_NODES_SWITCH=""
if [[ "$MP_ENABLE_AUTOSCALING" == "true" ]]; then
  MP_NODES_SWITCH="--enable-autoscaling --min-replicas ${MP_MIN_REPLICAS} --max-replicas ${MP_MAX_REPLICAS}"
else
  MP_NODES_SWITCH="--replicas ${MP_REPLICAS}"
fi

TUNING_CONFIG_SWITCH=""
if [[ "$USE_TUNING_CONFIG" == "true" ]]; then
  tuning_config_file=$(cat "${SHARED_DIR}/tuning_config_file")
  TUNING_CONFIG_SWITCH="--tuning-configs ${tuning_config_file}"
fi

SPOT_INSTANCES_SWITCH=""
if [[ "$USE_SPOT_INSTANCES" == "true" ]]; then
  SPOT_INSTANCES_SWITCH="--use-spot-instances --spot-max-price ${SPOT_MAX_PRICE}"
fi

LOCAL_ZONE_SWITCH=""
if [[ "$LOCAL_ZONE" == "true" ]]; then
  LOCAL_ZONE_SWITCH=""
  # Unify rosa localzones macnine pool config with ocp
  LABELS="${LABELS},node-role.kubernetes.io/edge="
  TAINTS="${TAINTS},node-role.kubernetes.io/edge=:NoSchedule"
  localzone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
  if [[ -z "${localzone_subnet_id}" ]]; then
    echo -e "The localzone_subnet_id is mandatory."
    exit 1
  fi

  LOCAL_ZONE_SWITCH="--subnet ${localzone_subnet_id}"
fi

MP_OPENSHIFT_VERSION_SWITCH=""
if [[ ! -z "$MP_OPENSHIFT_VERSION" ]]; then
  MP_OPENSHIFT_VERSION_SWITCH="--version ${MP_OPENSHIFT_VERSION}"
fi

# Create machine pool on the cluster
function createMachinepool() {
  subfix=$(openssl rand -hex 2)
  MP_NAME="mp-$subfix"
  
  ZONE=$1
  AZ_SWITCH=""
  if [[ ! -z "$ZONE" ]]; then
    AZ_SWITCH="--availability-zone ${ZONE}"
  fi

  AUTO_REPAIR_SWITCH=""
  if [[ "$HOSTED_CP" == "true" ]]; then
    AUTO_REPAIR_SWITCH="--autorepair"
  fi

  echo -e "Create machine pool ${MP_NAME} on the cluster ${CLUSTER_ID} ...
rosa create machinepool -y \
-c ${CLUSTER_ID}
--name ${MP_NAME} \
--instance-type ${MP_MACHINE_TYPE} \
--labels ${LABELS} \
--taints ${TAINTS} \
${MP_NODES_SWITCH} \
${TUNING_CONFIG_SWITCH} \
${SPOT_INSTANCES_SWITCH} \
${AZ_SWITCH} \
${LOCAL_ZONE_SWITCH} \
${MP_OPENSHIFT_VERSION_SWITCH} \
${AUTO_REPAIR_SWITCH}
"

rosa create machinepool -y \
                        -c ${CLUSTER_ID} \
                        --name ${MP_NAME} \
                        --instance-type ${MP_MACHINE_TYPE} \
                        --labels ${LABELS} \
                        --taints ${TAINTS} \
                        ${MP_NODES_SWITCH} \
                        ${TUNING_CONFIG_SWITCH} \
                        ${SPOT_INSTANCES_SWITCH} \
                        ${AZ_SWITCH} \
                        ${LOCAL_ZONE_SWITCH} \
                        ${MP_OPENSHIFT_VERSION_SWITCH} \
                        ${AUTO_REPAIR_SWITCH}
} 


if [[ ! -z "$MP_ZONE" ]]; then
  MP_ZONE="${CLOUD_PROVIDER_REGION}${MP_ZONE}"
fi

if [[ "$HOSTED_CP" == "false" ]]; then
  createMachinepool "$MP_ZONE"
else
  ZONES=$(rosa describe cluster -c ${CLUSTER_ID} -o json | jq -r ".nodes.availability_zones[]")
  for i in ${ZONES}; do
    createMachinepool "$i"
  done
fi

rosa list machinepools -c ${CLUSTER_ID}
