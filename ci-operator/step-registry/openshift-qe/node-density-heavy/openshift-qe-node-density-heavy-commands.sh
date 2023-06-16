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

git clone https://github.com/cloud-bulldozer/e2e-benchmarking
pushd e2e-benchmarking/workloads/kube-burner
export WORKLOAD=node-density-heavy

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker | grep -v "NotReady\\|SchedulingDisabled" | wc -l | xargs)
export NODE_COUNT=$(($current_worker_count))

export CLEANUP_WHEN_FINISH=true

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export COMPARISON_CONFIG="clusterVersion.json podLatency.json containerMetrics.json kubelet.json etcd.json crio.json nodeMasters-max.json nodeWorkers.json"
export GEN_CSV=true
export GSHEET_KEY_LOCATION="${CLUSTER_PROFILE_DIR}/gce.json"
export EMAIL_ID_FOR_RESULTS_SHEET='qili@redhat.com'

./run.sh
