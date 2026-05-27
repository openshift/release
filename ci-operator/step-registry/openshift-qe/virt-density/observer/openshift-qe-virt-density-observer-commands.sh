#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

function vd_cleanup() {

  echo "killing virt-density observer"
  date
  jobs -l
  if [[ -n $(jobs -l | grep "$vd_pid" | grep "Running") ]]; then
    kill -15 ${vd_pid}
  fi
  exit 0
  
}

trap vd_cleanup EXIT SIGTERM SIGINT

pushd /tmp
if [[ "${E2E_VERSION}" != "default" ]]; then
    git clone "https://github.com/cloud-bulldozer/e2e-benchmarking" /tmp/e2e-benchmarking --branch "${E2E_VERSION}" --depth 1
    pushd /tmp/e2e-benchmarking/workloads/kube-burner-ocp-wrapper
else
    pushd /e2e-benchmarking/workloads/kube-burner-ocp-wrapper
fi

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

export WORKLOAD=virt-density

EXTRA_FLAGS+=" --metrics-profile metrics.yml,cnv-metrics.yml --gc-metrics=false --vms-per-node=$VMS_PER_NODE --vmi-ready-threshold=${VMI_READY_THRESHOLD}s --profile-type=${PROFILE_TYPE} --burst=${BURST} --qps=${QPS}"

export ES_SERVER=""

if [[ "${CHURN}" == "true" ]]; then
    EXTRA_FLAGS+="  --namespaced-iterations=true"
fi

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=false --profile-type=${PROFILE_TYPE}"
export EXTRA_FLAGS

mkdir -p ${ARTIFACT_DIR}/virt-density
vd_logs=${ARTIFACT_DIR}/virt-density/vd_observer_logs.out

./run.sh > $vd_logs 2>&1 &

vd_pid="$!"
ps -ef | grep run


while [[ -z $(cat $vd_logs | grep "signal=terminated") ]]; do 
  sleep 10
  date
done
