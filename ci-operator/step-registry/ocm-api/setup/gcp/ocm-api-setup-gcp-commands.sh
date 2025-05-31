#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}


trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export TEST_PROFILE=${TEST_PROFILE:-}
export VERSION=${VERSION:-}
export CHANNEL_GROUP=${CHANNEL_GROUP:-}

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"


ocmTempDir=$(mktemp -d)
cd $ocmTempDir
git clone https://gitlab.cee.redhat.com/service/ocm-backend-tests.git
cd ocm-backend-tests/
make cmds
cp ./testcmd/* /usr/local/bin/
export ORG_MEMBER_TOKEN=$OCM_TOKEN
ocmqe test --service=cms --job=ocp-e2e-gcp-staging-main > "${CLUSTER_PREPARE_LOG}" || true

if [[ "${CLUSTER_PREPARE_LOG}" =~ "1 Failed" ]] ; then
  echo "${CLUSTER_PREPARE_LOG}"
  exit 1 
fi

CLUSTER_ID=$(cat "$(pwd)"/output/$TEST_PROFILE/cluster-id)

if [[ "${CLUSTER_STATE}" == "ready" ]]; then
  logger "Error" "The cluster-id is empty"
  exit 1 
fi

CLUSTER_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.name')

# Store the cluster ID for the post steps and the cluster deprovision
mkdir -p "${SHARED_DIR}"
echo -n "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log"

# Print console.url
CONSOLE_URL=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.console.url')
logger "INFO" "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"

PRODUCT_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.infra_id')
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
