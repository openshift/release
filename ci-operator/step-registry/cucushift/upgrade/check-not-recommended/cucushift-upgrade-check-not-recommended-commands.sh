#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"

echo "Upgrade target is ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
export TARGET_VERSION

retry=5
while (( retry > 0 )); do
    unrecommended_conditional_updates=$(oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True")) | .release.version' | xargs)
    echo "Not recommended conditions: "
    echo "${unrecommended_conditional_updates}"
    if [[ -z "${unrecommended_conditional_updates}" ]]; then
        retry=$((retry - 1))
        sleep 60
        echo "No conditionalUpdates update available! Retry..."
    else
        #shellcheck disable=SC2076
        if [[ "$unrecommended_conditional_updates" == *"failure determine thanos IP"* ]]; then
            echo "Warning: Thanos IP is not ready, clearing CVO cache"
            oc delete pod -n openshift-cluster-version -l k8s-app=cluster-version-operator
            echo "Waiting for the CVO pod to restart..."
            timeout=120
            while (( timeout > 0 )); do
                sleep 30
                (( timeout -= 30 ))
                # Check the status of the CVO pod
                pod_status=$(oc get pods -n openshift-cluster-version -l k8s-app=cluster-version-operator -o jsonpath='{.items[0].status.phase}')               
                if [ "$pod_status" == "Running" ]; then
                    echo "CVO pod has restarted"
                    break
                fi
            done
            if (( timeout <= 0 )); then
                echo "CVO pod did not restart within the 2 minutes, exit" && exit 1
            fi
            continue
        fi
        #shellcheck disable=SC2076
        if [[ " $unrecommended_conditional_updates " =~ " $TARGET_VERSION " ]]; then
            echo "Error: $TARGET_VERSION is not recommended, for details please refer:"
            oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True"))'
            exit 1
        fi
        break
    fi
done
