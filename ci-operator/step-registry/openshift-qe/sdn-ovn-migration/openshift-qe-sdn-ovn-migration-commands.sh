#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc config view
oc projects

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone -b sdn-ovn-migration $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/sdn-ovn-migration
export WORKLOAD=sdn-ovn-migration

# The measurable run
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export COMPARISON_CONFIG="clusterVersion.json podLatency.json containerMetrics.json kubelet.json etcd.json crio.json nodeMasters-max.json nodeWorkers.json"
export GEN_CSV=true
export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'
export ITERATIONS=$ITERATION_MULTIPLIER_ENV
export GC=false
echo ${SHARED_DIR}

./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)

jq ".iterations = $PODS_PER_NODE" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
#sdn-ovn-migration test
