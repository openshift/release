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

GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

git clone https://github.com/cloud-bulldozer/e2e-benchmarking --depth=1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

if [[ $WORKLOAD == *"cluster-density-v2"* ]]; then
    current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
    # Run a non-indexed warmup for scheduling inconsistencies
    ES_SERVER="" EXTRA_FLAGS="--gc=true" ITERATIONS=${current_worker_count} CHURN=false ./run.sh
    
    # The measurable run
    iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
    export ITERATIONS=$(($iteration_multiplier*$current_worker_count))
    export EXTRA_FLAGS+=" --gc-metrics=$GC_METRICS "    

elif [[ $WORKLOAD == *"node-density-heavy"* ]]; then
    # Run a non-indexed warmup for scheduling inconsistencies
    ES_SERVER="" EXTRA_FLAGS="--gc=true --pods-per-node=50" ./run.sh
    
    # The measurable run
    export EXTRA_FLAGS="--gc-metrics=$GC_METRICS --pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE"

elif [[ $WORKLOAD == *"node-density"* ]]; then  
    # Run a non-indexed warmup for scheduling inconsistencies
    ES_SERVER="" EXTRA_FLAGS="--gc=true --pods-per-node=50 --pod-ready-threshold=60s" ./run.sh
   
    # The measurable run
    export EXTRA_FLAGS="--gc-metrics=$GC_METRICS --pods-per-node=$PODS_PER_NODE --pod-ready-threshold=$POD_READY_THRESHOLD"

elif [[ $WORKLOAD == *"node-density-cni"* ]]; then
    # Run a non-indexed warmup for scheduling inconsistencies
    ES_SERVER="" EXTRA_FLAGS="--gc=true --pods-per-node=50" ./run.sh
    
    # The measurable run
    export EXTRA_FLAGS="--gc-metrics=$GC_METRICS --pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE"
fi

    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

rm -f ${SHARED_DIR}/index.json
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
if [[ $WORKLOAD == *"cluster-density-v2"* ]]; then
    jq ".iterations = $ITERATIONS" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json
else 
    jq ".iterations = $PODS_PER_NODE" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json
fi