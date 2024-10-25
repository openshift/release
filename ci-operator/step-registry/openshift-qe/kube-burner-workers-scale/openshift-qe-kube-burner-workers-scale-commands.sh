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
EXTRA_FLAGS="${METRIC_PROFILES} --additional-worker-nodes ${ADDITIONAL_WORKER_NODES} --enable-autoscaler=${ENABLE_AUTOSCALER}" 

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

if [ -z "$START_TIME" ] && [ -f "${SHARED_DIR}/workers_scale_event_epoch.txt" ]; then
  START_TIME=$(cat "${SHARED_DIR}/workers_scale_event_epoch.txt")
  export START_TIME
  rm -f "${SHARED_DIR}/workers_scale_event_epoch.txt"
fi

if [ -z "$END_TIME" ] && [ -f "${SHARED_DIR}/workers_scale_end_epoch.txt" ]; then
  END_TIME=$(cat "${SHARED_DIR}/workers_scale_end_epoch.txt")
  export END_TIME
  rm -f "${SHARED_DIR}/workers_scale_end_epoch.txt"
fi

export EXTRA_FLAGS

./run.sh
