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

GITHUB_API_URL="https://api.github.com/repos/$(echo "$E2E_REPO_URL" | sed "s|https://github.com/||")"
LATEST_TAG=$(curl -s "$GITHUB_API_URL/releases/latest" | jq -r '.tag_name')
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $E2E_REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/network-perf-v2

# Clean up resources from possible previous tests.
oc delete ns netperf --wait=true --ignore-not-found=true

# Only store the results from the full run versus the smoke test.
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

export TOLERANCE=90

rm -f ${SHARED_DIR}/index.json

WORKLOAD=full-run.yaml ./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json
