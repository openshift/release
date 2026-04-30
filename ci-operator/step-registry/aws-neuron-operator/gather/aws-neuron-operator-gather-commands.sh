#!/bin/bash

set -o nounset
set -o pipefail

echo "Collecting Neuron operator diagnostic data"

TOOLS_DIR="/tmp/tools"
mkdir -p "${TOOLS_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"

if ! command -v oc &>/dev/null; then
    echo "oc not found, downloading OpenShift client..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        | tar xzf - -C "${TOOLS_DIR}" oc kubectl 2>/dev/null || true
fi

if ! command -v jq &>/dev/null; then
    echo "jq not found, downloading..."
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o "${TOOLS_DIR}/jq" \
        && chmod +x "${TOOLS_DIR}/jq" || true
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
DUMP_DIR="${ARTIFACT_DIR}/neuron-gather"
mkdir -p "${DUMP_DIR}"

oc get modules.kmm.sigs.x-k8s.io -A -o yaml > "${DUMP_DIR}/kmm-modules.yaml" 2>&1 || true
oc get pods -A -o wide > "${DUMP_DIR}/all-pods.txt" 2>&1 || true
oc get pods -n openshift-kmm -o wide > "${DUMP_DIR}/kmm-pods.txt" 2>&1 || true
oc get daemonsets -A -o wide > "${DUMP_DIR}/daemonsets.txt" 2>&1 || true
oc get events -A --sort-by='.lastTimestamp' > "${DUMP_DIR}/events.txt" 2>&1 || true
oc get nodes -o json | jq '.items[].status.images[] | select(.names[] | test("neuron"))' > "${DUMP_DIR}/node-neuron-images.json" 2>&1 || true
oc describe nodes > "${DUMP_DIR}/nodes-describe.txt" 2>&1 || true
oc get csv -A -o yaml > "${DUMP_DIR}/csvs.yaml" 2>&1 || true
oc get subscriptions -A -o yaml > "${DUMP_DIR}/subscriptions.yaml" 2>&1 || true

oc logs -n openshift-kmm -l app.kubernetes.io/component=kmm --tail=1000 > "${DUMP_DIR}/kmm-operator-logs.txt" 2>&1 || true

NEURON_NS=$(oc get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("neuron")) | .metadata.namespace' | head -1 || true)
if [[ -n "${NEURON_NS}" ]]; then
    oc logs -n "${NEURON_NS}" -l app.kubernetes.io/name=aws-neuron-operator --tail=1000 > "${DUMP_DIR}/neuron-operator-logs.txt" 2>&1 || true
    oc get all -n "${NEURON_NS}" -o wide > "${DUMP_DIR}/neuron-ns-resources.txt" 2>&1 || true
    oc get events -n "${NEURON_NS}" --sort-by='.lastTimestamp' > "${DUMP_DIR}/neuron-ns-events.txt" 2>&1 || true
fi

KSERVE_DIR="${DUMP_DIR}/kserve"
INFERENCE_NAMESPACE="${INFERENCE_NAMESPACE:-neuron-inference}"
mkdir -p "${KSERVE_DIR}"
oc get inferenceservice -A -o yaml > "${KSERVE_DIR}/inferenceservices.yaml" 2>&1 || true
oc get servingruntime -A -o yaml > "${KSERVE_DIR}/servingruntimes.yaml" 2>&1 || true
oc get datasciencecluster -A -o yaml > "${KSERVE_DIR}/datascienceclusters.yaml" 2>&1 || true
oc get knativeserving -A -o yaml > "${KSERVE_DIR}/knativeserving.yaml" 2>&1 || true
oc get pods -n "${INFERENCE_NAMESPACE}" -o wide > "${KSERVE_DIR}/inference-pods.txt" 2>&1 || true
oc get events -n "${INFERENCE_NAMESPACE}" --sort-by='.lastTimestamp' > "${KSERVE_DIR}/inference-events.txt" 2>&1 || true
oc get ksvc -n "${INFERENCE_NAMESPACE}" -o yaml > "${KSERVE_DIR}/knative-services.yaml" 2>&1 || true

echo "Neuron diagnostic data collected in ${DUMP_DIR}"
