#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
mkdir -p "${ARTIFACT_DIR}"

cd /home/testuser

if [[ -n "${CLUSTER_PROFILE_DIR:-}" && -f "${CLUSTER_PROFILE_DIR}/kmm-pull-secret" ]]; then
    export ECO_HWACCEL_KMM_PULL_SECRET
    ECO_HWACCEL_KMM_PULL_SECRET="$(cat "${CLUSTER_PROFILE_DIR}/kmm-pull-secret")"
    echo "KMM external-registry credentials loaded from the cluster profile"
else
    echo "No KMM external-registry credentials found; external-registry tests may skip"
fi

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-modules}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-kmm-sanity && !bmc && !simple-kmod}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_VERBOSE_LEVEL="${ECO_VERBOSE_LEVEL:-100}"
export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"
export ECO_REPORTS_DUMP_DIR="${ARTIFACT_DIR}"
export ECO_HWACCEL_KMM_REGISTRY="${ECO_HWACCEL_KMM_REGISTRY:-quay.io/ocp-edge-qe}"
export ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE="${ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE:-quay.io/cvultur/device-plugin:latest-%s}"

if ! oc wait --for=condition=Available \
    deployment.apps/image-registry \
    --namespace openshift-image-registry --timeout=10m; then
    oc get configs.imageregistry.operator.openshift.io/cluster \
        -o yaml > "${ARTIFACT_DIR}/image-registry-config.yaml" 2>&1 || true
    oc get pods -n openshift-image-registry -o wide \
        > "${ARTIFACT_DIR}/image-registry-pods.txt" 2>&1 || true
    echo "The OpenShift integrated registry is not Available" >&2
    exit 1
fi

echo "Running eco-gotests KMM features: ${ECO_TEST_FEATURES}"
echo "Running eco-gotests KMM labels: ${ECO_TEST_LABELS}"

test_rc=0
./scripts/test-runner.sh \
    --junit-report="${ARTIFACT_DIR}/junit_kmm_modules.xml" \
    --json-report="${ARTIFACT_DIR}/ginkgo.json" \
    --output-dir="${ARTIFACT_DIR}" \
    || test_rc=$?

echo "=== Collecting KMM diagnostics ==="
oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
oc get modules.kmm.sigs.x-k8s.io --all-namespaces -o yaml > "${ARTIFACT_DIR}/kmm-modules.yaml" 2>&1 || true
oc get pods --all-namespaces -o wide > "${ARTIFACT_DIR}/pods.txt" 2>&1 || true
oc get events --all-namespaces --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/events.txt" 2>&1 || true
oc get pods -n openshift-kmm -o wide > "${ARTIFACT_DIR}/kmm-pods.txt" 2>&1 || true
oc logs -n openshift-kmm -l app.kubernetes.io/component=kmm --tail=500 > "${ARTIFACT_DIR}/kmm-operator-logs.txt" 2>&1 || true
echo "=== KMM diagnostics collected ==="

exit "${test_rc}"
