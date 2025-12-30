#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

# Clean up leftovers for previous test
oc delete projects -l kube-burner-job=init-served-job
oc delete projects -l kube-burner-job=create-serviceaccounts-job
oc delete AdminPolicyBasedExternalRoute --all

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

UUID=$(uuidgen)

# Inicialize the environment
WORKLOAD=web-burner-init EXTRA_FLAGS="--uuid=${UUID} --gc=false --sriov=true --alerting=true --check-health=true --local-indexing=false --bfd=${BFD} --limitcount=${LIMIT_COUNT} --scale=${SCALE} --crd=${CRD} --profile-type=${PROFILE_TYPE}" ./run.sh

# The web-burner node-density or cluster-density run
EXTRA_FLAGS="--uuid=${UUID} --gc=${GC} --sriov=true --alerting=true --check-health=true --probe=${PROBE} --bfd=${BFD} --limitcount=${LIMIT_COUNT} --scale=${SCALE} --crd=${CRD} --profile-type=${PROFILE_TYPE}" ./run.sh

# Clean up
oc delete projects -l kube-burner-job=init-served-job
oc delete projects -l kube-burner-job=create-serviceaccounts-job
oc delete AdminPolicyBasedExternalRoute --all
