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
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply an ocm-token or SSO credentials!"
  exit 1
fi

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
