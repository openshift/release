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

git clone https://github.com/cloud-bulldozer/e2e-benchmarking --depth=1
pushd e2e-benchmarking/workloads/network-perf-v2

# Clean up resources from possible previous tests.
oc delete ns netperf --wait=true --ignore-not-found=true

# UUID Generation
UUID="CPT-$(uuidgen)"
export UUID

# Only store the results from the full run versus the smoke test.
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

export TOLERANCE=90

rm -rf "${SHARED_DIR}/${OUTPUT_FILE:?}"

WORKLOAD=full-run.yaml ./run.sh |& tee "${SHARED_DIR}/${OUTPUT_FILE}"
