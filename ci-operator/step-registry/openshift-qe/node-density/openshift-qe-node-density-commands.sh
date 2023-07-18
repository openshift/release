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

git clone --branch vchalla https://github.com/vishnuchalla/e2e-benchmarking --depth=1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export EXTRA_FLAGS="--pods-per-node=$PODS_PER_NODE --pod-ready-threshold=$POD_READY_THRESHOLD"
export WORKLOAD=node-density

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

rm -rf "${SHARED_DIR}/${OUTPUT_FILE:?}"
PROW_JOB_START=$(date +"%Y-%m-%d %H:%M:%S")
./run.sh |& tee "${SHARED_DIR}/${OUTPUT_FILE}"
if [ $? -eq 0 ]; then
  PROW_JOB_STATUS="success"
else
  PROW_JOB_STATUS="failure"
fi
PROW_JOB_END=$(date +"%Y-%m-%d %H:%M:%S")

export PROW_JOB_START
export PROW_JOB_END
export PROW_JOB_STATUS
popd
pushd e2e-benchmarking/utils
./index.sh
