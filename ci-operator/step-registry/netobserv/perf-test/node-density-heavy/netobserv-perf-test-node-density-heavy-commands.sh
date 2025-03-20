#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# get NetObserv metadata 
NETOBSERV_RELEASE=$(oc get pods -l app=netobserv-operator -o jsonpath="{.items[*].spec.containers[0].env[?(@.name=='OPERATOR_CONDITION_NAME')].value}" -A)
LOKI_RELEASE=$(oc get sub -n openshift-operators-redhat loki-operator -o jsonpath="{.status.currentCSV}")
KAFKA_RELEASE=$(oc get sub -n openshift-operators amq-streams  -o jsonpath="{.status.currentCSV}")
opm --help
if [[ $INSTALLATION_SOURCE == "Internal" ]]; then
    NOO_BUNDLE_INFO=$(build_info.sh)
else
    # Currently hardcoded as main until https://issues.redhat.com/browse/NETOBSERV-2054 is fixed
    NOO_BUNDLE_INFO="v0.0.0-main"
fi

# TODO, Add: # PR info?
export ADDITIONAL_PARAMS="{\"release\": \"$NETOBSERV_RELEASE\", \"loki_version\": \"$LOKI_RELEASE\", \"kafka_version\": \"$KAFKA_RELEASE\", \"noo_bundle_info\"=\"$NOO_BUNDLE_INFO\"}"


# Run node-density-heavy in background

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
export WORKLOAD=node-density-heavy

# A non-indexed warmup run
#ES_SERVER="" EXTRA_FLAGS="--pods-per-node=50  --pod-ready-threshold=2m" ./run.sh
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"


declare -A WORKLOAD_PIDS

# Kick off run with vars set

EXTRA_FLAGS="--gc-metrics=true --pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE --profile-type=${PROFILE_TYPE}" CLEANUP_WHEN_FINISH=true ./run.sh &> /tmp/node-density-heavy-run.log &
WORKLOAD_PIDS["node-density-heavy"]=$!
#node_density_heavy_pid=$!

# wait 5 mins before starting ingress-perf
sleep 300 

# Run ingress-perf
popd
pushd e2e-benchmarking/workloads/ingress-perf
ES_INDEX="ingress-performance" ./run.sh &> /tmp/ingress-perf-run.log &
WORKLOAD_PIDS["ingress-perf"]=$!
#ingress_perf_pid=$!

function check_pids(){
    pid_rc=$1
    returned_pid=$2
    if [[ $pid_rc == "1" ]]; then
        if [[ $returned_pid == "${WORKLOAD_PIDS["node-density-heavy"]}" ]]; then
            echo "===> node-density-heavy failed; exit code: $ended_pid_rc. Killing ingress-perf"
            kill -9 "${WORKLOAD_PIDS["ingress-perf"]}" 
        else
            echo "===> ingress-perf failed; exit code: $ended_pid_rc. Killing node-density-heavy"
            kill -9 "${WORKLOAD_PIDS["node-density-heavy"]}"
        fi
    else
        if [[ $returned_pid == "${WORKLOAD_PIDS["node-density-heavy"]}" ]]; then
            echo "===> node-density-heavy completed successfully"
        else
            echo "===> ingress-perf completed successfully"
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

NODE_DENSITY_HEAVY_UUID=$(grep 'uuid"' /tmp/node-density-heavy-run.log | cut -d'"' -f 4)
INGRESS_PERF_UUID=$(grep 'uuid"' /tmp/ingress-perf-run.log | cut -d'"' -f 4)

if [[ -d /tmp/"$NODE_DENSITY_HEAVY_UUID" &&  -f /tmp/"$NODE_DENSITY_HEAVY_UUID"/index_data.json ]]; then
        jq ".iterations = $PODS_PER_NODE"  >> /tmp/"$NODE_DENSITY_HEAVY_UUID"/index_data.json
        cp /tmp/"$NODE_DENSITY_HEAVY_UUID"/index_data.json "${ARTIFACT_DIR}"/${WORKLOAD}-index_data.json
        cp /tmp/"$NODE_DENSITY_HEAVY_UUID"/index_data.json "${SHARED_DIR}"/${WORKLOAD}-index_data.json
fi

if [[ -d /tmp/"$INGRESS_PERF_UUID" && -f /tmp/"$INGRESS_PERF_UUID"/index_data.json ]]; then
    cp /tmp/"$INGRESS_PERF_UUID"/index_data.json "${ARTIFACT_DIR}"/ingress-perf-index_data.json
    cp /tmp/"$INGRESS_PERF_UUID"/index_data.json "${SHARED_DIR}"/ingress-perf-index_data.json
fi

echo "######## Node-density-heavy run logs ########"
cat /tmp/node-density-heavy-run.log
cp /tmp/node-density-heavy-run.log "$ARIFACT_DIR"
echo "################"

printf "\n\n\n\n\n"

echo "######## ingress-perf run logs ########"
cat /tmp/ingress-perf-run.log
cp /tmp/ingress-perf-run.log "$ARTIFACT_DIR"
echo "################"

exit "$ended_pid_rc"
