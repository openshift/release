#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp


git clone https://github.com/vishnuchalla/e2e-benchmarking --branch v0.0.1 --depth 1
pushd e2e-benchmarking
pushd workloads/kube-burner-ocp-wrapper
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi
export WORKLOAD=egressip
current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
ES_SERVER="" ITERATIONS=${current_worker_count} CHURN=false ./run.sh
