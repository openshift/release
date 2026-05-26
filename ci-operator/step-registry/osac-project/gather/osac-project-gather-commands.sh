#!/bin/bash

set -o nounset
set -o pipefail

echo "************ osac-project-gather: collecting OSAC pod logs ************"

REMOTE_ARTIFACT_DIR="/tmp/osac-artifacts"

timeout -s 9 10m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" "${REMOTE_ARTIFACT_DIR}" <<'REMOTE_EOF'
set -o nounset
set -o pipefail

E2E_NAMESPACE="$1"
ARTIFACT_DIR="$2"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
if [[ -z "${KUBECONFIG}" ]]; then
    echo "No kubeconfig found, skipping log collection"
    exit 0
fi

mkdir -p "${ARTIFACT_DIR}"

echo "Gathering OSAC logs from namespace ${E2E_NAMESPACE}..."

oc get pods -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/pods.txt" 2>&1 || true
oc get events -n "${E2E_NAMESPACE}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/events.txt" 2>&1 || true
oc describe pods -n "${E2E_NAMESPACE}" > "${ARTIFACT_DIR}/pods-describe.txt" 2>&1 || true
oc get deployments -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/deployments.txt" 2>&1 || true
oc get jobs -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/jobs.txt" 2>&1 || true
oc get statefulsets -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/statefulsets.txt" 2>&1 || true

for pod in $(oc get pods -n "${E2E_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    for container in $(oc get pod "${pod}" -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" > "${ARTIFACT_DIR}/pod-${pod}-${container}.log" 2>&1 || true
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod-${pod}-${container}-previous.log" 2>/dev/null || true
    done
    for container in $(oc get pod "${pod}" -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
        oc logs "${pod}" -n "${E2E_NAMESPACE}" -c "${container}" > "${ARTIFACT_DIR}/pod-${pod}-init-${container}.log" 2>&1 || true
    done
done

for ns in keycloak ansible-aap; do
    if oc get namespace "${ns}" &>/dev/null; then
        mkdir -p "${ARTIFACT_DIR}/${ns}"
        oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/pods.txt" 2>&1 || true
        oc get events -n "${ns}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/${ns}/events.txt" 2>&1 || true
        oc describe pods -n "${ns}" > "${ARTIFACT_DIR}/${ns}/pods-describe.txt" 2>&1 || true
        oc get deployments -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/deployments.txt" 2>&1 || true
        oc get jobs -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/jobs.txt" 2>&1 || true
        oc get statefulsets -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}/statefulsets.txt" 2>&1 || true
        for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
                oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/${ns}/pod-${pod}-${container}.log" 2>&1 || true
                oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/${ns}/pod-${pod}-${container}-previous.log" 2>/dev/null || true
            done
            for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
                oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/${ns}/pod-${pod}-init-${container}.log" 2>&1 || true
            done
        done
    fi
done

echo "=== Collecting CNV/virtualization diagnostics ==="
mkdir -p "${ARTIFACT_DIR}/cnv"
oc get hyperconverged -A -o yaml > "${ARTIFACT_DIR}/cnv/hyperconverged.yaml" 2>&1 || true
oc get vms -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vms.txt" 2>&1 || true
oc get vmis -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vmis.txt" 2>&1 || true
oc get datavolumes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/datavolumes.txt" 2>&1 || true
oc get pvc -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/pvcs.txt" 2>&1 || true
oc get events -n openshift-cnv --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/cnv/events-openshift-cnv.txt" 2>&1 || true

echo "=== Collecting compute instance status ==="
oc get computeinstances -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/computeinstances.txt" 2>&1 || true
oc get computeinstances -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/computeinstances.yaml" 2>&1 || true

echo "=== Collecting node resource usage ==="
oc adm top node > "${ARTIFACT_DIR}/node-resources.txt" 2>&1 || true
oc adm top pod -n "${E2E_NAMESPACE}" --sort-by=memory > "${ARTIFACT_DIR}/pod-resources.txt" 2>&1 || true
oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
oc describe node > "${ARTIFACT_DIR}/node-describe.txt" 2>&1 || true

echo "=== Collecting cluster operator status ==="
oc get co > "${ARTIFACT_DIR}/clusteroperators.txt" 2>&1 || true
oc get csv -n openshift-cnv -o wide > "${ARTIFACT_DIR}/cnv/csv.txt" 2>&1 || true

echo "=== Collecting AAP operator status ==="
oc get ansibleautomationplatform -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/aap-status.yaml" 2>&1 || true
oc get automationcontroller -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/automationcontroller-status.yaml" 2>&1 || true

echo "Log collection complete"
REMOTE_EOF

echo "Copying artifacts from remote machine..."
timeout -s 9 5m scp -r -F "${SHARED_DIR}/ssh_config" "ci_machine:${REMOTE_ARTIFACT_DIR}" "${ARTIFACT_DIR}/osac-logs" 2>&1 || true

echo "************ osac-project-gather: done ************"
