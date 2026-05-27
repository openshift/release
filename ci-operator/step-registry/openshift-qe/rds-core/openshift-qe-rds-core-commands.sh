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

if [[ "${E2E_VERSION}" != "default" ]]; then
    git clone "https://github.com/cloud-bulldozer/e2e-benchmarking" /tmp/e2e-benchmarking --branch "${E2E_VERSION}" --depth 1
    pushd /tmp/e2e-benchmarking/workloads/kube-burner-ocp-wrapper
else
    pushd /e2e-benchmarking/workloads/kube-burner-ocp-wrapper
fi

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

WORKLOAD=rds-core EXTRA_FLAGS+=" --alerting=true --profile-type=${PROFILE_TYPE}" ./run.sh
