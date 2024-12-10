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
    pushd workloads/kube-burner
    ES_PASSWORD=$(cat "/secret/perfscale-prod/password")
    ES_USERNAME=$(cat "/secret/perfscale-prod/username")
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-perfscale-pro-wxrjvmobqs7gsyi3xvxkqmn7am.us-west-2.es.amazonaws.com"
    export JOB_TIMEOUT=${JOB_TIMEOUT:=21600}
    current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
    export WORKLOAD=${WORKLOAD:=networkpolicy-case1}

    case $WORKLOAD in
        networkpolicy-case1)
            JOB_ITERATIONS=$(( 5 * $current_worker_count ))
            ;;

        networkpolicy-case2)
            JOB_ITERATIONS=$(( 1 * $current_worker_count ))
            ;;

        networkpolicy-case3)
            JOB_ITERATIONS=$(( 4 * $current_worker_count ))
            ;;
        *)
            echo Unsupported $WORKLOAD workload type
            ;;
    esac
    
    echo $JOB_ITERATIONS is JOB_ITERATIONS
    export JOB_ITERATIONS
    ./run.sh
else
    echo "We are sorry, this job is only meant for cloud-bulldozer/e2e-benchmarking repo PR testing"
fi
