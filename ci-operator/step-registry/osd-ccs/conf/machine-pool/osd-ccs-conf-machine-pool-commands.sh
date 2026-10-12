#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

suffix=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
MACHINE_POOL_NAME=${MACHINE_POOL_NAME:-"ci-mp-$suffix"}
MACHINE_POOL_INSTANCE_TYPE=${MACHINE_POOL_INSTANCE_TYPE:-"m5.xlarge"}
ENABLE_AUTOSCALING=${ENABLE_AUTOSCALING:-false}
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Switches
REPLICA_SWITCH=""
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  REPLICA_SWITCH="--enable-autoscaling --min-replicas ${MIN_REPLICAS} --max-replicas ${MAX_REPLICAS}"
else
  REPLICA_SWITCH="--replicas ${REPLICAS}"
fi

LABEL_SWITCH=""
if [[ ! -z "$LABELS" ]]; then
  LABEL_SWITCH="--labels ${LABELS}"
fi

# Create machine pool
echo "Create machine pool ..."
echo -e "
ocm create machinepool ${MACHINE_POOL_NAME} \
--cluster ${CLUSTER_ID} \
--instance-type ${MACHINE_POOL_INSTANCE_TYPE} \
${REPLICA_SWITCH} \
${LABEL_SWITCH}
"

ocm create machinepool ${MACHINE_POOL_NAME} \
                       --cluster "${CLUSTER_ID}" \
                       --instance-type "${MACHINE_POOL_INSTANCE_TYPE}" \
                       ${REPLICA_SWITCH} \
                       ${LABEL_SWITCH}
echo -e "Machine pool ${MACHINE_POOL_NAME} is created successfully"
