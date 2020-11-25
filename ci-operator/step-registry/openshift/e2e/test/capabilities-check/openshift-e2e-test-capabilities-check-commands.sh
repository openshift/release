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
    # The status of the mcp worker doesn't immediately change
    # to updating, it takes a few seconds, hence the sleep here.
    sleep 1m
    echo "waiting for the changes to roll out"
    oc wait --for=condition=Updating=false mcp/worker --timeout=600s
    echo "done waiting"
fi

# create a fedora pod and get the capabilities enabled in the pod
oc run fedora-pod --image fedora --restart Never --command -- sleep 1000
oc wait --for=condition=Ready pod/fedora-pod --timeout=300s
capabilities=$(oc rsh fedora-pod capsh --print)

# get the capabilities MCs available
workerMC=$(oc get mc/99-worker-generated-crio-capabilities -o name; true)
masterMC=$(oc get mc/99-master-generated-crio-capabilities -o name; true)
# Since we are only deleting the worker caps MC for the test, the master caps MC should
# exist. If it does, this means we have the capabilities patch so we should go ahead and
# check the capabilities.
if [[ "${workerMC}" == "" ]] && [[ "${masterMC}" != "" ]]; then
    if [[ "${capabilities}" == *"net_raw"* ]]; then
        echo "No worker capabilities MCs were found, but the restricted scc still has NET_RAW enabled"
        exit 1
    fi
elif [[ "${workerMC}" != "" ]]; then
    if [[ "${capabilities}" != *"net_raw"* ]]; then
        echo "Worker capabilities MC was found, but the restricted scc does not have NET_RAW enabled"
        exit 1
    fi
fi

# delete the pod
oc delete pod fedora-pod
