#!/bin/bash

set -o nounset
set -o pipefail

echo "Collecting Neuron operator diagnostic data"

if ! command -v oc &>/dev/null; then
    echo "oc not found, downloading OpenShift client..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        | tar xzf - -C /usr/local/bin oc kubectl 2>/dev/null || true
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

echo "Neuron diagnostic data collected in ${DUMP_DIR}"
