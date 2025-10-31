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

EXTRA_FLAGS+=" --gc-metrics=true --pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE --profile-type=${PROFILE_TYPE} --burst=${BURST} --qps=${QPS} --pprof=${PPROF}"

export CLEANUP_WHEN_FINISH=true

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export COMPARISON_CONFIG="clusterVersion.json podLatency.json containerMetrics.json kubelet.json etcd.json crio.json nodeMasters-max.json nodeWorkers.json"
export GEN_CSV=true
export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'

echo ${SHARED_DIR}
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)

jq ".iterations = $PODS_PER_NODE" $folder_name/index_data.json >> "${SHARED_DIR}"/index_data.json

cp "${SHARED_DIR}"/index_data.json "${SHARED_DIR}"/${WORKLOAD}-index_data.json 
cp "${SHARED_DIR}"/${WORKLOAD}-index_data.json  "${ARTIFACT_DIR}"/${WORKLOAD}-index_data.json

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

#node-density-heavy test
if [[ ${PPROF} == "true" ]]; then
  cp -r pprof-data "${ARTIFACT_DIR}/"
fi
