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

GITHUB_API_URL="https://api.github.com/repos/$(echo "$E2E_REPO_URL" | sed "s|https://github.com/||")"
LATEST_TAG=$(curl -s "$GITHUB_API_URL/releases/latest" | jq -r '.tag_name')
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $E2E_REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/network-perf-v2

# Clean up
oc delete ns netperf --wait=true --ignore-not-found=true

# Smoke Test
./run.sh
