#!/bin/bash

set -ex

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export KUBEVIRT_PROVIDER=external
export IMAGE_BUILDER="${IMAGE_BUILDER:-podman}"
export DEV_IMAGE_REGISTRY="${DEV_IMAGE_REGISTRY:-quay.io}"
export KUBEVIRTCI_RUNTIME="${KUBEVIRTCI_RUNTIME:-podman}"
export NAMESPACE="${HANDLER_NAMESPACE:-openshift-nmstate}"

if [ "${CI}" == "true" ]; then
    source ${SHARED_DIR}/packet-conf.sh
    export SSH="./hack/ssh-ci.sh"
else
    export SSH="./hack/ssh.sh"
fi

# When MIRROR_IMAGES=false, devscripts leaves the image registry in Removed
# managementState. Set it to Managed with emptyDir storage early so it has
# time to deploy while nmstate installs, avoiding test failures from a missing
# registry during conformance runs.
registry_state=$(oc get configs.imageregistry.operator.openshift.io/cluster \
    -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "")
if [ "${registry_state}" = "Removed" ]; then
    echo "Image registry is Removed, setting to Managed with emptyDir storage..."
    oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
        -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
fi

make cluster-sync-operator
oc create -f test/e2e/nmstate.yaml

# Wait for handler pods to be created and ready
while ! oc get pods -n ${NAMESPACE} | grep handler; do sleep 1; done
while oc get pods -n ${NAMESPACE} | grep "0/1"; do sleep 1; done

# Wait for all cluster operators to stabilize before handing off to the
# conformance test step.
echo "Waiting for cluster operators to finish progressing..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=30m
