#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp

if [[ "$JOB_TYPE" == "presubmit" ]] && [[ "$REPO_OWNER" = "cloud-bulldozer" ]] && [[ "$REPO_NAME" = "e2e-benchmarking" ]]; then
    git clone https://github.com/${REPO_OWNER}/${REPO_NAME}
    pushd ${REPO_NAME}
    git config --global user.email "ocp-perfscale@redhat.com"
    git config --global user.name "ocp-perfscale"
    git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
    git switch ${PULL_NUMBER}
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
    ES_SERVER="" PPROF=false ITERATIONS=${current_worker_count} CHURN=false ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
