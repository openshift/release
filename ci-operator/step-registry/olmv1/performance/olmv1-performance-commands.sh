#!/bin/bash
set -euxo pipefail

cat /etc/os-release
oc version
oc get co
oc get nodes
oc get clustercatalog
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

# connected to ES server
ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

KUBE_DIR=${KUBE_DIR:-/tmp}
EXTRA_FLAGS=${EXTRA_FLAGS:-}
ITERATIONS=${ITERATIONS:-300}

# cannot clone openshift-tests-private repo directly, so use tests-private-burner image
# copy olm-metrics.yml and extended-metrics.yml 
cp /go/src/github.com/openshift/openshift-tests-private/test/extended/operators/benchmark/metrics/* ${KUBE_DIR}

# use e2e-benchmarking
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
# LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
# TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
# git clone $REPO_URL $TAG_OPTION --depth 1
git clone $REPO_URL --branch master --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=olm LOG_LEVEL=debug 

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --metrics-profile=${KUBE_DIR}/olm-metrics.yml,${KUBE_DIR}/extended-metrics.yml --gc-metrics=false --profile-type=${PROFILE_TYPE}"

export EXTRA_FLAGS ADDITIONAL_PARAMS ITERATIONS

rm -f ${SHARED_DIR}/index.json
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $ITERATIONS" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

cp "${SHARED_DIR}"/index_data.json "${SHARED_DIR}"/${WORKLOAD}-index_data.json 
cp "${SHARED_DIR}"/${WORKLOAD}-index_data.json  "${ARTIFACT_DIR}"/${WORKLOAD}-index_data.json

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

echo "OLMv1 benchmark test finised"
