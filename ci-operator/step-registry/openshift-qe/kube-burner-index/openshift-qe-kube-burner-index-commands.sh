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

REPO_URL=${E2E_REPOSITORY:-"https://github.com/cloud-bulldozer/e2e-benchmarking"};
LATEST_TAG=$(curl -s "https://api.github.com/repos/${REPO_URL#https://github.com}/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL e2e-benchmarking $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=index
EXTRA_FLAGS=$METRIC_PROFILES

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

if [ -z "$START_TIME" ] && [ -f "${SHARED_DIR}/workload_start_time.txt" ]; then
  START_TIME=$(cat "${SHARED_DIR}/workload_start_time.txt")
  export START_TIME
  rm -f "${SHARED_DIR}/workload_start_time.txt"
fi

if [ -z "$END_TIME" ] && [ -f "${SHARED_DIR}/workload_end_time.txt" ]; then
  END_TIME=$(cat "${SHARED_DIR}/workload_end_time.txt")
  export END_TIME
  rm -f "${SHARED_DIR}/workload_end_time.txt"
fi

if [ -f "${SHARED_DIR}/workload_user_metadata.yaml" ]; then
  EXTRA_FLAGS+=" --user-metadata ${SHARED_DIR}/workload_user_metadata.yaml"
fi

export EXTRA_FLAGS
export START_TIME=${START_TIME:-$(date -d "-1 hour" +%s)};
export END_TIME=${END_TIME:-$(date +%s)};
elapsed_time=$((END_TIME - START_TIME))
export ELAPSED="${elapsed_time}s"

./run.sh
