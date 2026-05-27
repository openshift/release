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

export KUBE_BURNER_URL="https://github.com/cloud-bulldozer/kube-burner/releases/download/v0.17.3/kube-burner-0.17.3-Linux-x86_64.tar.gz"

if [[ "${E2E_VERSION}" != "default" ]]; then
    git clone "https://github.com/cloud-bulldozer/e2e-benchmarking" /tmp/e2e-benchmarking --branch "${E2E_VERSION}" --depth 1
    pushd /tmp/e2e-benchmarking/workloads/kube-burner
else
    pushd /e2e-benchmarking/workloads/kube-burner
fi
export WORKLOAD=concurrent-builds

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

./run.sh
