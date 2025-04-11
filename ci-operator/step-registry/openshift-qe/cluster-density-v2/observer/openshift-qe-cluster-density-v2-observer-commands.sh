#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

pushd /tmp
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1

python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc version

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

echo "kubeconfig loc $KUBECONFIG"

if [[ $WAIT_FOR_NS == "true" ]]; then
  while [ "$(oc get ns | grep -c 'start-kraken')" -lt 1 ]; do
    echo "start kraken not found yet, waiting"
    sleep 10
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


./run.sh
rc=$?

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $ITERATIONS" $folder_name/index_data.json >> ${ARTIFACT_DIR}/index_data.json


if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

echo "{'cluster_density': $rc}" >> ${ARTIFACT_DIR}/observer_status.json

echo "Return code: $rc"
exit $rc