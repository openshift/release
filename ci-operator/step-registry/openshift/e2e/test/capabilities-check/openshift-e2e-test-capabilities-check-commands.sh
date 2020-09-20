#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

cp -Lrvf ${KUBECONFIG} /tmp/kubeconfig && export KUBECONFIG=/tmp/kubeconfig
oc new-project e2e-test-capabilities-check

version=$(oc version -o json | jq -r '.openshiftVersion')
if [[ "${version}" == *"4.4"* ]]; then
    echo "version is less than 4.5, exiting"
    exit 0
fi

if [[ "${DELETE_MC}" == "true" ]]; then
    oc delete mc 99-worker-generated-crio-capabilities
    # need to wait for the changes to roll out
    # for debug purposes only
    echo "waiting for the changes to roll out"
    oc wait --for=condition=Updating=false mcp/worker --timeout=600s
    echo "done waiting"
fi

# create a fedora pod and get the capabilities enabled in the pod
oc run fedora-pod --image fedora --restart Never --command -- sleep 1000
oc wait --for=condition=Ready pod/fedora-pod --timeout=300s
capabilities=$(oc rsh fedora-pod capsh --print)
# for debug purposes only, will remove once tests are passing
echo "capabilities are ${capabilities}"

# get the capabilities MCs available
mcCaps=$(oc get mc/99-worker-generated-crio-capabilities -o name; true)
# for debug purposes only
echo "mc caps is ${mcCaps}"
if [[ "${mcCaps}" == "" ]]; then
    if [[ "${capabilities}" == *"net_raw"* ]]; then
        echo "No capabilities MCs were found, but the restricted scc still has NET_RAW enabled"
        exit 1
    fi
else
    if [[ "${capabilities}" != *"net_raw"* ]]; then
        echo "Capabilities MC was found, but the restricted scc does not have NET_RAW enabled"
        exit 1
    fi
fi

# delete the pod
oc delete pod fedora-pod
