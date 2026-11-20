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
  # Disable tracing: proxy-conf.sh may export HTTP_PROXY with an embedded password.
  set +x
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

oc config view
oc projects
pushd /tmp

UUID=$(uuidgen)
ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

set +x

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

#Support Libvirt Hypershift Cluster
cluster_infra=$(oc get  infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
hypershift_pods=$(! oc -n hypershift get pods| grep operator >/dev/null ||oc -n hypershift get pods| grep operator |wc -l)
if [[ $cluster_infra == "BareMetal" && $hypershift_pods -ge 1 ]];then
  echo "Executing berserker-load in hypershift cluster"
  echo "Configure KUBECONFIG for hosted cluster and execute kube-burner in it"
  export KUBECONFIG=$SHARED_DIR/nested_kubeconfig
fi

# Management Kubeconfig for ROSA-HCP
# Set this variable only for HCP clusters on AWS
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ ${CONTROL_PLANE_TOPOLOGY} == "External" && $cluster_infra == "AWS" ]]; then
    if [[ -f "${SHARED_DIR}/hs-mc.kubeconfig" ]]; then
        # Check if the cluster is accessible from prow environment,
        # Set this variable only if accessible
        MC_CLUSTER_INFRA=$(oc --kubeconfig="${SHARED_DIR}/hs-mc.kubeconfig" get  infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
        if [[ $MC_CLUSTER_INFRA == "AWS" ]]; then
            export MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
            export ES_INDEX=ripsaw-kube-burner
        fi
    fi
fi

REPO_URL="${E2E_REPO:-https://github.com/cloud-bulldozer/e2e-benchmarking}";
if [ "$E2E_VERSION" == "default" ]; then
  LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
  TAG_OPTION="--branch ${LATEST_TAG}"
else
  TAG_OPTION="--branch ${E2E_VERSION}"
fi
git clone $REPO_URL $TAG_OPTION --depth 1 e2e-benchmarking
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

# Download berserker-default-containers.yml since ReadFile template function reads from filesystem
# Determine kube-burner-ocp version from e2e-benchmarking run.sh
KB_OCP_VERSION=$(grep "KUBE_BURNER_VERSION=" run.sh | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
curl -sSfL "https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/v${KB_OCP_VERSION}/cmd/config/berserker-load/berserker-default-containers.yml" -o berserker-default-containers.yml
export BERSERKER_CONTAINERS_FILE="$PWD/berserker-default-containers.yml"

export PPROF=false  # Workaround for custom e2e-benchmarking fork that still references PPROF
export WORKLOAD=berserker-load
EXTRA_FLAGS="${BERSERKER_EXTRA_FLAGS} ${KB_FLAGS} --gc=${BERSERKER_GC} --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --job-iterations=${JOB_ITERATIONS}"
EXTRA_FLAGS+=" --job-pause=${JOB_PAUSE}"
EXTRA_FLAGS+=" --daemonset-replicas=${DAEMONSET_REPLICAS}"
EXTRA_FLAGS+=" --service-replicas=${SERVICE_REPLICAS}"
EXTRA_FLAGS+=" --churn-duration=${CHURN_DURATION}"
EXTRA_FLAGS+=" --churn-delay=${CHURN_DELAY}"
EXTRA_FLAGS+=" --churn-percent=${CHURN_PERCENT}"
EXTRA_FLAGS+=" --max-wait-timeout=${MAX_WAIT_TIMEOUT}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

export EXTRA_FLAGS UUID

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -d ${METRICS_FOLDER} ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
fi
if [[ -f ${METRICS_FOLDER}/jobSummary.json ]]; then
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

if [[ "${RUN_EXIT_CODE}" -eq 2 ]]; then
  echo "kube-burner returned exit code 2, which means the workload reached a timeout"
  echo "Checking cluster health before exiting"
  if /tmp/kube-burner-ocp cluster-health; then
    echo "Cluster is still healthy. Ignoring workload timeout to run remaining workloads"
    echo "Deleting any left-over test resources"
    oc delete ns -l kube-burner.io/uuid
    exit 0
  fi
fi

exit ${RUN_EXIT_CODE}
