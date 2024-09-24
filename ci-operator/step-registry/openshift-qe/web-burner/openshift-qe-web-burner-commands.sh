#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion "cat ~/bm/kubeconfig" > /tmp/kubeconfig
  # Setup socks proxy
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion -fNT -D 12345
  export KUBECONFIG=/tmp/kubeconfig
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig=/tmp/kubeconfig config set-cluster bm --proxy-url=socks5://localhost:12345
  cd /tmp
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

REPO_URL=${E2E_REPOSITORY:-"https://github.com/cloud-bulldozer/e2e-benchmarking"};
LATEST_TAG=$(curl -s "https://api.github.com/repos/${REPO_URL#https://github.com}/releases/latest" | jq -r '.tag_name');
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

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi