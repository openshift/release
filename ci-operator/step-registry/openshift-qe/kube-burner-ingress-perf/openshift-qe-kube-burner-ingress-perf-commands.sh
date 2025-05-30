#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -x

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
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# set ADDITIONAL_PARAMS for indexing.
ADDITIONAL_PARAMS_FILE="$SHARED_DIR/additional_params.json"
if [[ -f $ADDITIONAL_PARAMS_FILE ]]; then
    ADDITIONAL_PARAMS=$(cat "$ADDITIONAL_PARAMS_FILE")
    export ADDITIONAL_PARAMS
fi

declare -A WORKLOAD_PIDS

# Kick off run with vars set
if [[ $WORKLOAD == "node-density-heavy" ]]; then
    EXTRA_FLAGS+=" --gc-metrics=true --pods-per-node=$PODS_PER_NODE --profile-type=${PROFILE_TYPE}" CLEANUP_WHEN_FINISH=true ./run.sh &> "${ARTIFACT_DIR}/$WORKLOAD-run.log" &
fi

if [[ $WORKLOAD == "cluster-density-v2" ]]; then
    current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
    iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
    export ITERATIONS=$(($iteration_multiplier*$current_worker_count))
    EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}" ./run.sh &> "${ARTIFACT_DIR}/$WORKLOAD-run.log" &
fi

WORKLOAD_PIDS["$WORKLOAD"]=$!

# sleep 5 mins before triggering ingress-perf
sleep 300 

# Run ingress-perf
popd
pushd e2e-benchmarking/workloads/ingress-perf
ES_INDEX="ingress-performance" ./run.sh &> "${ARTIFACT_DIR}"/ingress-perf-run.log &
WORKLOAD_PIDS["ingress-perf"]=$!
#ingress_perf_pid=$!

function check_pids(){
    pid_rc=$1
    returned_pid=$2
    if [[ $pid_rc == "1" ]]; then
        if [[ $returned_pid == "${WORKLOAD_PIDS["$WORKLOAD"]}" ]]; then
            echo "===> $WORKLOAD failed; exit code: $ended_pid_rc. Killing ingress-perf"
            kill -9 "${WORKLOAD_PIDS["ingress-perf"]}" 
        else
            echo "===> ingress-perf failed; exit code: $ended_pid_rc. Killing $WORKLOAD"
            kill -9 "${WORKLOAD_PIDS["$WORKLOAD"]}"
        fi
    else
        if [[ $returned_pid == "${WORKLOAD_PIDS["$WORKLOAD"]}" ]]; then
            echo "===> $WORKLOAD completed successfully at $(date)"
        else
            echo "===> ingress-perf completed successfully at $(date)"
        fi
    fi
}

# wait until all background processes are finished and get return code
wait -n -p ended_pid
ended_pid_rc=$?
#shellcheck disable=SC2154
check_pids $ended_pid_rc $ended_pid
wait -n -p ended_pid
ended_pid_rc=$?
#shellcheck disable=SC2154
check_pids $ended_pid_rc $ended_pid

NODE_DENSITY_HEAVY_UUID=$(grep 'uuid"' "${ARTIFACT_DIR}/$WORKLOAD-run.log" | cut -d'"' -f 4)
INGRESS_PERF_UUID=$(grep 'uuid"' "${ARTIFACT_DIR}/ingress-perf-run.log" | cut -d'"' -f 4)

echo "===> $WORKLOAD UUID $NODE_DENSITY_HEAVY_UUID"
echo "===> ingress-perf UUID $INGRESS_PERF_UUID"

if [[ -d "/tmp/$NODE_DENSITY_HEAVY_UUID" &&  -f "/tmp/$NODE_DENSITY_HEAVY_UUID/index_data.json" ]]; then
    jq ".iterations = $PODS_PER_NODE"  >> "/tmp/$NODE_DENSITY_HEAVY_UUID/index_data.json"
    cp "/tmp/$NODE_DENSITY_HEAVY_UUID"/index_data.json "${ARTIFACT_DIR}/${WORKLOAD}-index_data.json"
    cp "/tmp/$NODE_DENSITY_HEAVY_UUID/index_data.json" "${SHARED_DIR}/${WORKLOAD}-index_data.json"
fi

if [[ -d "/tmp/$INGRESS_PERF_UUID" && -f "/tmp/$INGRESS_PERF_UUID/index_data.json" ]]; then
    cp "/tmp/$INGRESS_PERF_UUID/index_data.json" "${ARTIFACT_DIR}/ingress-perf-index_data.json"
    cp "/tmp/$INGRESS_PERF_UUID/index_data.json" "${SHARED_DIR}/ingress-perf-index_data.json"
fi

echo "######## $WORKLOAD run logs ########"
cat  "${ARTIFACT_DIR}/$WORKLOAD-run.log"
echo "################"

printf "\n\n\n\n\n"

echo "######## ingress-perf run logs ########"
cat  "${ARTIFACT_DIR}/ingress-perf-run.log"
echo "################"

exit "$ended_pid_rc"
