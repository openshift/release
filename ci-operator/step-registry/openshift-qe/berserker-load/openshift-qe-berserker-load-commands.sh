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

oc config view
oc projects
pushd /tmp

UUID=$(uuidgen)
ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

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

export PPROF=false  # Workaround for custom e2e-benchmarking fork that still references PPROF
export WORKLOAD=berserker-load
EXTRA_FLAGS="${BERSERKER_EXTRA_FLAGS} ${KB_FLAGS} --gc=${BERSERKER_GC} --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --job-iterations=${JOB_ITERATIONS}"
EXTRA_FLAGS+=" --job-pause=${JOB_PAUSE}"
EXTRA_FLAGS+=" --process-load-replicas=${PROCESS_LOAD_REPLICAS}"
EXTRA_FLAGS+=" --endpoint-load-replicas=${ENDPOINT_LOAD_REPLICAS}"
EXTRA_FLAGS+=" --connection-load-replicas=${CONNECTION_LOAD_REPLICAS}"
EXTRA_FLAGS+=" --churn-duration=${CHURN_DURATION}"
EXTRA_FLAGS+=" --churn-delay=${CHURN_DELAY}"
EXTRA_FLAGS+=" --churn-percent=${CHURN_PERCENT}"
EXTRA_FLAGS+=" --process-load-image=${PROCESS_LOAD_IMAGE}"
EXTRA_FLAGS+=" --endpoint-load-image=${ENDPOINT_LOAD_IMAGE}"
EXTRA_FLAGS+=" --connection-load-image=${CONNECTION_LOAD_IMAGE}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

export EXTRA_FLAGS UUID

./run.sh

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
