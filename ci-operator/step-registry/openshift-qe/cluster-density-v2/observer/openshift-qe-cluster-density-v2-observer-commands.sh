#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

function cd_cleanup() {

  echo "killing cd-v2 observer"
  date
  jobs -l
  if [[ -n $(jobs -l | grep "$cd_pid" | grep "Running") ]]; then
    kill -15 ${cd_pid}
  fi
  exit 0
  
}

trap cd_cleanup EXIT SIGTERM SIGINT

pushd /tmp
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1

python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc version

while [ ! -f "${KUBECONFIG}" ]; do
  sleep 30
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

if [[ $WAIT_FOR_NS == "true" ]]; then
  while [ "$(oc get ns | grep -c 'start-kraken')" -lt 1 ]; do
    sleep 30
  done
fi

pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=cluster-density-v2

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

# The measurable run
iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
export ITERATIONS=$(($iteration_multiplier*$current_worker_count))

export ES_SERVER=""

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}"
export EXTRA_FLAGS

mkdir -p ${ARTIFACT_DIR}/cluster-density
cd_logs=${ARTIFACT_DIR}/cluster-density/cd_observer_logs.out

./run.sh > $cd_logs 2>&1 &

cd_pid="$!"
ps -ef | grep run


while [[ -z $(cat $cd_logs | grep "signal=terminated") ]]; do 
  sleep 10
  date
done