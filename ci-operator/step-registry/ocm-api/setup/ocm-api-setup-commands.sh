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
export NAME_PREFIX=${NAME_PREFIX:-}

function gcloud_auth() {
  local service_project_id

  if ! which gcloud; then
    GCLOUD_TAR="google-cloud-sdk-468.0.0-linux-x86_64.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
    logger "INFO" "gcloud not installed, installing from $GCLOUD_URL"
    pushd ${HOME}
    curl -O "$GCLOUD_URL"
    tar -xzf "$GCLOUD_TAR"
    export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
    popd
  fi

  # login to the service project
  service_project_id="$(jq -r -c .project_id "${GCP_SHARED_CREDENTIALS_FILE}")"
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${service_project_id}"
}
# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

ocmTempDir=$(mktemp -d)
cd $ocmTempDir
wget https://gitlab.cee.redhat.com/service/ocm-backend-tests/-/archive/master/ocm-backend-tests-master.tar.gz --no-check-certificate
tar -zxf ocm-backend-tests-master.tar.gz
mv ocm-backend-tests-master ocm-backend-tests
cd ocm-backend-tests/
make cmds
chmod +x ./testcmd/*
cp ./testcmd/* $ocmTempDir/
export PATH=$ocmTempDir:$PATH
export ORG_MEMBER_TOKEN=${OCM_TOKEN}
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json
export CLUSTER_PROFILE=${TEST_PROFILE}
export CLUSTER_PROFILE_DIR=${ocmTempDir}
export OCM_ENV=${OCM_LOGIN_ENV}
export OCPE2E_TEST=true
export DEBUG=false
export QE_FLAG="prow-test"
export QE_USAGE="prow-test"

gcloud_auth

logger "INFO" "Start to prepare cluster: cms --ginkgo.v --ginkgo.no-color --ginkgo.timeout 2h --ginkgo.focus CreateClusterByYAMLProfile --ginkgo.label-filter feature-cluster-creation "
cms --ginkgo.v --ginkgo.no-color --ginkgo.timeout 2h --ginkgo.focus CreateClusterByYAMLProfile --ginkgo.label-filter feature-cluster-creation 

IDline=$(cat $CLUSTER_PROFILE_DIR/cluster.ini|grep "^\s*ID\s*=");
echo $IDline|awk -F " " '{print $NF}' > "${SHARED_DIR}/cluster-id"
cp $CLUSTER_PROFILE_DIR/cluster.ini ${SHARED_DIR}/

# Store the cluster information
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.name')
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

