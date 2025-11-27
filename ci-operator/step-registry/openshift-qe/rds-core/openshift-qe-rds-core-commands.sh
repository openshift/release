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

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";

# Clone e2e-benchmarking repository
if [ -n "${E2E_BENCHMARKING_PR}" ]; then
  echo "Cloning e2e-benchmarking repository and checking out PR #${E2E_BENCHMARKING_PR}"
  git clone $REPO_URL
  pushd e2e-benchmarking
  # Update GIT Global user settings
  git config --global user.name "RedHat Performance"
  git config --global user.email "redhat-performance@redhat.com"

  git pull origin pull/${E2E_BENCHMARKING_PR}/head:${E2E_BENCHMARKING_PR} --rebase
  git switch ${E2E_BENCHMARKING_PR}
  popd
else
  echo "Cloning e2e-benchmarking repository using tag/version"
  LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
  TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
  git clone $REPO_URL $TAG_OPTION --depth 1
fi

pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"


# RUN THE WORKLOAD
if [ "$CHURN" == "true" ]; then
  EXTRA_FLAGS="${EXTRA_FLAGS} --churn-cycles ${CHURN_CYCLES} --churn-percent ${CHURN_PERCENT} --dpdk-devicepool ${SRIOV_DPDK_DEVICEPOOL} --net-devicepool ${SRIOV_NET_DEVICEPOOL}"
fi

WORKLOAD=rds-core PERFORMANCE_PROFILE=${PERFORMANCE_PROFILE} EXTRA_FLAGS="${EXTRA_FLAGS} --profile-type=${PROFILE_TYPE}" ./run.sh
