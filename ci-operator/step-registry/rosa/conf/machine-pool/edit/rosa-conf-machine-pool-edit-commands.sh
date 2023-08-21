#!/bin/bash

# https://docs.openshift.com/rosa/rosa_cluster_admin/rosa_nodes/rosa-nodes-about-autoscaling-nodes.html
# https://www.rosaworkshop.io/rosa/7-managing_nodes/#adding-node-labels
# https://access.redhat.com/documentation/en-us/red_hat_openshift_service_on_aws/4/html/rosa_cli/rosa-managing-objects-cli#rosa-edit-machinepool_rosa-managing-objects-cli
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")


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
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Switches
EDIT_LABELS=""
if [[ ! -z "$MP_LABELS" ]]; then
  # need to get current labels and then add on new ones
  current_labels=rosa list machinepool -c $CLUSTER_ID -o json | jq -r '.[] | select(.id == "$MP_NAME")' | jq .labels 
#{
#  "test": "worker2"
#}
  ## edit labels to be 
  EDIT_LABELS=" --labels ${MP_LABELS}"
fi

EDIT_TAINTS=""
if [[ ! -z "$MP_TAINTS" ]]; then
  EDIT_TAINTS=" --taints ${TAINTS},${MP_TAINTS}"
fi

EDIT_MACHINE_TYPE=""
if [[ ! -z "$MP_MACHINE_TYPE" ]]; then
  EDIT_MACHINE_TYPE=" --instance-type ${MP_MACHINE_TYPE}"
fi

# Edit a machine pool on the cluster
function editMachinePool() {
  
  ZONE=$1
  AZ_SWITCH=""
  if [[ ! -z "$ZONE" ]]; then
    AZ_SWITCH="--availability-zone ${ZONE}"
  fi

  echo -e " Edit machine pool ${MP_NAME} on the cluster ${CLUSTER_ID} ...
rosa edit machinepool -y \
-c ${CLUSTER_ID}
--name ${MP_NAME} \
${EDIT_MACHINE_TYPE} \
${EDIT_LABELS} \
${EDIT_TAINTS} \
${AZ_SWITCH} \
"

rosa edit machinepool -y \
    -c ${CLUSTER_ID} \
    --name ${MP_NAME} \
    ${EDIT_MACHINE_TYPE} \
    ${EDIT_LABELS} \
    ${EDIT_TAINTS} \
    ${AZ_SWITCH} 
} 


if [[ ! -z "$MP_ZONE" ]]; then
  MP_ZONE="${CLOUD_PROVIDER_REGION}${MP_ZONE}"
fi

if [[ "$HOSTED_CP" == "false" ]]; then
  editMachinePool "$MP_ZONE"
else
  ZONES=$(rosa describe cluster -c ${CLUSTER_ID} -o json | jq -r ".nodes.availability_zones[]")
  for i in ${ZONES}; do
    editMachinePool "$i"
  done
fi

rosa list machinepools -c ${CLUSTER_ID}
