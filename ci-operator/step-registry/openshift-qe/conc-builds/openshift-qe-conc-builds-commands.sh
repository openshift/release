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

git clone https://github.com/lenahorsley/e2e-benchmarking/ --depth=1
pushd e2e-benchmarking/workloads/kube-burner
export WORKLOAD=concurrent-builds

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

rm -rf "${SHARED_DIR}/${OUTPUT_FILE:?}"
./run.sh |& tee "${SHARED_DIR}/${OUTPUT_FILE}"
