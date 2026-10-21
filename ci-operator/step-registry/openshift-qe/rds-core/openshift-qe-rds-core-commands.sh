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

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# RUN THE WORKLOAD

if [ -n "${CHURN_CYCLES}" ]; then
  EXTRA_FLAGS="${EXTRA_FLAGS} --churn-cycles ${CHURN_CYCLES} --churn-percent ${CHURN_PERCENT}"
fi

if [ -n "${SRIOV_DPDK_DEVICEPOOL}" ]; then
  EXTRA_FLAGS="${EXTRA_FLAGS} --dpdk-devicepool ${SRIOV_DPDK_DEVICEPOOL}"
fi

if [ -n "${SRIOV_NET_DEVICEPOOL}" ]; then
  EXTRA_FLAGS="${EXTRA_FLAGS} --net-devicepool ${SRIOV_NET_DEVICEPOOL}"
fi

set +o errexit
WORKLOAD=rds-core EXTRA_FLAGS+=" --alerting=true --profile-type=${PROFILE_TYPE}" ./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
if [[ -d ${METRICS_FOLDER} ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
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