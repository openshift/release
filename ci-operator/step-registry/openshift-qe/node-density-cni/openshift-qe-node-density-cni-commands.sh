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

git clone https://github.com/cloud-bulldozer/e2e-benchmarking
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export EXTRA_FLAGS="--pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE"

export WORKLOAD=node-density-cni

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# UUID Generation
UUID="CPT-$(uuidgen)"
export UUID

rm -rf "${SHARED_DIR}/${OUTPUT_FILE:?}"
./run.sh |& tee "${SHARED_DIR}/${OUTPUT_FILE}"