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
export WORKLOAD=node-density

# A non-indexed warmup run
ES_SERVER="" EXTRA_FLAGS="--pods-per-node=50 --pod-ready-threshold=60s" ./run.sh

# The measurable run
EXTRA_FLAGS="--gc-metrics=true --pods-per-node=$PODS_PER_NODE --pod-ready-threshold=$POD_READY_THRESHOLD --profile-type=${PROFILE_TYPE}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

if [[ "${USE_HORREUM_WEBHOOK}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS

rm -f ${SHARED_DIR}/index.json

./run.sh 

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $PODS_PER_NODE" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

if [[ "${USE_HORREUM_WEBHOOK}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
