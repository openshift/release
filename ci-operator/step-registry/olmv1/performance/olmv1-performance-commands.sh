#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
# cat /etc/os-release
# oc config view
# oc projects
oc version
oc get co
oc get nodes
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

# ES_SERVER=${ES_SERVER=https://USER:PASSWORD@HOSTNAME:443}
LOG_LEVEL=${LOG_LEVEL:-debug}

# download kube-burner-ocp
KUBE_DIR=${KUBE_DIR:-/tmp}
KUBE_BURNER_VERSION=${KUBE_BURNER_VERSION:-1.6.8}
PERFORMANCE_PROFILE=${PERFORMANCE_PROFILE:-default}
CHURN=${CHURN:-true}
PPROF=${PPROF:-true}
ARCHIVE=${ARCHIVE:-true}
WORKLOAD=${WORKLOAD:?}
QPS=${QPS:-20}
BURST=${BURST:-20}
GC=${GC:-true}
EXTRA_FLAGS=${EXTRA_FLAGS:-}
UUID=${UUID:-$(uuidgen)}


KUBE_BURNER_URL="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_VERSION}/kube-burner-ocp-V${KUBE_BURNER_VERSION}-linux-x86_64.tar.gz"
curl --fail --retry 8 --retry-all-errors -sS -L "${KUBE_BURNER_URL}" | tar -xzC "${KUBE_DIR}/" kube-burner-ocp

# git clone https://github.com/kube-burner/kube-burner-ocp.git --branch main --depth 1
# pushd kube-burner-ocp
# make build
# ./bin/amd64/kube-burner-ocp olm -h

# REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
# LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
# TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
# git clone $REPO_URL $TAG_OPTION --depth 1
# pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
# export WORKLOAD=olm

export ITERATIONS=30
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

  METADATA=$(cat << EOF
{
"uuid": "${UUID}",
"workload": "${WORKLOAD}",
"mgmtClusterName": "${MC_NAME}",
"hostedClusterName": "${HC_NAME}",
"timestamp": "$(date +%s%3N)"
}
EOF
)


if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}"

export EXTRA_FLAGS
export ADDITIONAL_PARAMS

export WORKLOAD=olm LOG_LEVEL=debug

cmd="${KUBE_DIR}/kube-burner-ocp ${WORKLOAD} --log-level=${LOG_LEVEL} --qps=${QPS} --burst=${BURST} --gc=${GC} --uuid ${UUID} --iterations=${ITERATIONS}"

# If ES_SERVER is specified
if [[ -n ${ES_SERVER} ]]; then
  curl -k -sS -X POST -H "Content-type: application/json" ${ES_SERVER}/ripsaw-kube-burner/_doc -d "${METADATA}" -o /dev/null
  cmd+=" --es-server=${ES_SERVER} --es-index=ripsaw-kube-burner"
fi
# If PERFORMANCE_PROFILE is specified
if [[ -n ${PERFORMANCE_PROFILE} && ${WORKLOAD} =~ "rds-core" ]]; then
  cmd+=" --perf-profile=${PERFORMANCE_PROFILE}"
fi

# Enable pprof collection
if $PPROF; then
  cmd+=" --pprof"
fi

# Capture the exit code of the run, but don't exit the script if it fails.
set +e

echo $cmd
JOB_START=${JOB_START:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
$cmd
exit_code=$?
JOB_END=${JOB_END:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
if [ $exit_code -eq 0 ]; then
  JOB_STATUS="success"
else
  JOB_STATUS="failure"
fi

wget http://github.com/cloud-bulldozer/e2e-benchmarking/blob/master/utils/index.sh
export JOB_START="$JOB_START" JOB_END="$JOB_END" JOB_STATUS="$JOB_STATUS" UUID="$UUID" WORKLOAD="$WORKLOAD" ES_SERVER="$ES_SERVER" 
source index.sh || true


rm -f ${SHARED_DIR}/index.json

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $ITERATIONS" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

cp "${SHARED_DIR}"/index_data.json "${SHARED_DIR}"/${WORKLOAD}-index_data.json 
cp "${SHARED_DIR}"/${WORKLOAD}-index_data.json  "${ARTIFACT_DIR}"/${WORKLOAD}-index_data.json


if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

echo "OLMv1 benchmark test finised"
