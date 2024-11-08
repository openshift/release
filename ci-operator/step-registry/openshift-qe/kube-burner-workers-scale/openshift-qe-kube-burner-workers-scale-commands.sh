#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=workers-scale
export GC=$GARBAGE_COLLECTION

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

ROSA_SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
ROSA_SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

if [[ -n "${ROSA_SSO_CLIENT_ID}" && -n "${ROSA_SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with SSO credentials"
  rosa login --env "${ROSA_LOGIN_ENV}" --client-id "${ROSA_SSO_CLIENT_ID}" --client-secret "${ROSA_SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

EXTRA_FLAGS="${METRIC_PROFILES} --additional-worker-nodes ${ADDITIONAL_WORKER_NODES} --enable-autoscaler=${DEPLOY_AUTOSCALER}" 

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

if [ "$DEPLOY_AUTOSCALER" = "false" ] && [ -f "${SHARED_DIR}/workers_scale_event_epoch.txt" ] && [ -f "${SHARED_DIR}/workers_scale_end_epoch.txt" ]; then
  START_TIME=$(cat "${SHARED_DIR}/workers_scale_event_epoch.txt")
  export START_TIME
  END_TIME=$(cat "${SHARED_DIR}/workers_scale_end_epoch.txt")
  export END_TIME
  EXTRA_FLAGS="${METRIC_PROFILES} --scale-event-epoch ${START_TIME}" 
  rm -f "${SHARED_DIR}/workers_scale_event_epoch.txt"
  rm -f "${SHARED_DIR}/workers_scale_end_epoch.txt"
fi

export EXTRA_FLAGS

./run.sh
