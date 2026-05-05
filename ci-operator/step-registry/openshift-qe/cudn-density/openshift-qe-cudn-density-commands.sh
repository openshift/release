#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc config view
oc projects
oc version

UUID=$(uuidgen)

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

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

# The measurable run
# Use CUDN_ITERATION_MULTIPLIER if set, fall back to ITERATION_MULTIPLIER_ENV, default to 15
# Use awk for fractional multiplier support; result is rounded down to nearest multiple of
# NAMESPACES_PER_CUDN since cudn-density requires iterations to be divisible by namespaces-per-cudn.
# Recommended per-job multipliers:
#   6 nodes:   15    -> 90 iterations
#   24 nodes:  10.42 -> 250 iterations
#   120 nodes: 2.09  -> 250 iterations
#   252 nodes: 1     -> 250 iterations
iteration_multiplier=${CUDN_ITERATION_MULTIPLIER:-${ITERATION_MULTIPLIER_ENV:-15}}
if [[ -n "$OVERRIDE_ITERATIONS" ]]; then
  export ITERATIONS=$OVERRIDE_ITERATIONS
else
  ITERATIONS=$(awk "BEGIN {v=int($iteration_multiplier * $current_worker_count); printf \"%d\", v - (v % $NAMESPACES_PER_CUDN)}")
  export ITERATIONS
fi


export WORKLOAD=cudn-density
EXTRA_FLAGS+="${KB_FLAGS} --local-indexing --layer3=${ENABLE_LAYER_3} --namespaces-per-cudn=${NAMESPACES_PER_CUDN} --gc-metrics=false --pod-ready-threshold=$POD_READY_THRESHOLD --profile-type=${PROFILE_TYPE} --pprof=${PPROF} --job-pause=10m"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

export EXTRA_FLAGS UUID

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -f ${METRICS_FOLDER}/jobSummary.json ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
  if [[ ${JOB_NAME} == *openshift-eng-ocp-qe-perfscale-ci* ]] && [[ ${JOB_TYPE} == "periodic" ]]; then
    set +e
    OCP_PERF_DASH_HOST=$(cat ${ES_SECRETS_PATH}/ocp-perf-dash-address)
    OCP_PERF_DASH_DIR="/usr/share/ocp-perf-dash/${JOB_NAME}/${WORKLOAD}/${UUID}"
    METRICS="${METRICS_FOLDER}/*QuantilesMeasurement*.json ${METRICS_FOLDER}/jobSummary.json"
    SSH_ARGS="-i ${ES_SECRETS_PATH}/ocp-perf-dash-id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh ${SSH_ARGS} ${OCP_PERF_DASH_HOST} "mkdir -p ${OCP_PERF_DASH_DIR}"
    scp ${SSH_ARGS} ${METRICS} ${OCP_PERF_DASH_HOST}:${OCP_PERF_DASH_DIR}
    set -e
  fi
fi

if [[ ${PPROF} == "true" ]]; then
  cp -r pprof-data "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
