#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=network-policy

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

# On a freshly deployed environment, we am getting high and inconsistent latency for the first time. However the later runs giving us the consistent latency. So adding a dry run with 20 iterations to stabilize the environment before running the scale iterations to have consistent latency.
export ITERATIONS=20

EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE} --pods-per-namespace ${PODS_PER_NAMESPACE} --netpol-per-namespace ${NETPOL_PER_NAMESPACE} --local-pods ${LOCAL_PODS} --single-ports ${SINGLE_PORTS} --port-ranges ${PORT_RANGES} --remotes-namespaces ${REMOTE_NAMESPACES} --remotes-pods ${REMOTE_PODS} --cidrs ${CIDR}"
export EXTRA_FLAGS

./run.sh

sleep 60

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
export ITERATIONS=$(($iteration_multiplier*$current_worker_count))

EXTRA_FLAGS+=" --netpol-ready-threshold=$NETPOL_READY_THRESHOLD"

./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
