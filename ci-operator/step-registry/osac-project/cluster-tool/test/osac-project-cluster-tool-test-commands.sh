#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool vmaas test ************"
echo "Running ALL vmaas tests sequentially"
echo "OSAC_TEST_IMAGE: ${OSAC_TEST_IMAGE}"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "-------------------------------------------"

CLONE_NAME="e2e"
KUBECONFIG_PATH="/root/.kube/${CLONE_NAME}.kubeconfig"
REMOTE_RESULTS_DIR="/tmp/test-results"

function collect_artifacts() {
    echo "Collecting test artifacts..."
    timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
        "ci_machine:${REMOTE_RESULTS_DIR}/junit_vmaas.xml" \
        "${ARTIFACT_DIR}/junit_vmaas.xml" 2>/dev/null || true

    echo "Collecting post-test diagnostics..."
    timeout -s 9 2m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" <<'DIAG_EOF' 2>/dev/null || true
export KUBECONFIG="/root/.kube/e2e.kubeconfig"
NS="$1"
echo "=== POST-TEST NODE RESOURCES ==="
oc adm top nodes 2>/dev/null || true
echo "=== POST-TEST POD RESOURCES (top 20 by memory) ==="
oc adm top pods -n "${NS}" --sort-by=memory 2>/dev/null | head -20 || true
echo "=== STUCK RESOURCES ==="
oc get computeinstance,virtualnetwork,subnet,securitygroup -n "${NS}" -o wide 2>/dev/null || true
echo "=== AUTOMATION JOB PODS ==="
for POD in $(oc get pods -n "${NS}" -l ansible_job --no-headers -o custom-columns=N:.metadata.name 2>/dev/null); do
    echo "--- ${POD} ---"
    oc get pod "${POD}" -n "${NS}" -o jsonpath='exitCode={.status.containerStatuses[0].state.terminated.exitCode} reason={.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true
    echo ""
done
DIAG_EOF
}
trap collect_artifacts EXIT

TEST_EXIT=0
timeout -s 9 60m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${E2E_NAMESPACE}" \
    "${E2E_VM_TEMPLATE}" \
    "${E2E_CLUSTER_TEMPLATE}" \
    "${OSAC_TEST_IMAGE}" \
    "${KUBECONFIG_PATH}" \
    "${REMOTE_RESULTS_DIR}" \
    <<'REMOTE_EOF' || TEST_EXIT=$?
set -euo pipefail

NAMESPACE="$1"
VM_TEMPLATE="$2"
CLUSTER_TEMPLATE="$3"
TEST_IMAGE="$4"
KUBECONFIG_PATH="$5"
RESULTS_DIR="$6"

mkdir -p "${RESULTS_DIR}"

export KUBECONFIG="${KUBECONFIG_PATH}"
echo "Waiting for KubeVirt to be Available..."
for attempt in $(seq 1 60); do
    AVAILABLE=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${AVAILABLE}" == "True" ]]; then
        echo "  KubeVirt Available after $((attempt * 10))s"
        break
    fi
    if [[ $((attempt % 6)) -eq 0 ]]; then
        PROGRESSING=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "unknown")
        echo "  [${attempt}0s] KubeVirt not Available yet: ${PROGRESSING}"
    fi
    sleep 10
done
if [[ "${AVAILABLE}" != "True" ]]; then
    echo "ERROR: KubeVirt not Available after 600s"
    oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o yaml 2>/dev/null || true
    exit 1
fi
unset KUBECONFIG

echo "=== PRE-TEST RESOURCE BASELINE ==="
export KUBECONFIG="${KUBECONFIG_PATH}"
oc adm top nodes 2>/dev/null || true
echo "Pod count in ${NAMESPACE}: $(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)"
lvs -a -o+data_percent,metadata_percent 2>/dev/null || true
df -h /home 2>/dev/null || true
unset KUBECONFIG

cat > /tmp/patch_helpers.py << 'PATCHEOF'
import os, subprocess, sys

def _dump_timeout_diagnostics(resource_type, name):
    ns = os.environ.get("OSAC_NAMESPACE", "osac-e2e-ci")
    print(f"\n=== TIMEOUT DIAGNOSTICS for {resource_type}/{name} ===", file=sys.stderr, flush=True)
    cmds = [
        f"kubectl get {resource_type} {name} -n {ns} -o yaml",
        f"kubectl get pods -n {ns} -l ansible_job -o wide",
        f"kubectl get events -n {ns} --sort-by=.lastTimestamp --field-selector type=Warning",
        "kubectl adm top nodes",
        f"kubectl adm top pods -n {ns} --sort-by=memory",
    ]
    for cmd in cmds:
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
            print(f"--- {cmd} ---\n{r.stdout[:3000]}", file=sys.stderr, flush=True)
        except Exception as e:
            print(f"--- {cmd} FAILED: {e} ---", file=sys.stderr, flush=True)
    print("=== END DIAGNOSTICS ===\n", file=sys.stderr, flush=True)

# Monkey-patch poll_until to dump diagnostics on timeout
import tests.core.runner as runner
_original_poll_until = runner.poll_until

def _instrumented_poll_until(**kwargs):
    try:
        return _original_poll_until(**kwargs)
    except TimeoutError:
        desc = kwargs.get("description", "")
        rtype = "computeinstance"
        for token, rt in [("VirtualNetwork", "virtualnetwork"), ("Subnet", "subnet"), ("SecurityGroup", "securitygroup"), ("ClusterOrder", "clusterorder")]:
            if token in desc:
                rtype = rt
                break
        name = desc.split()[-1] if desc else "unknown"
        _dump_timeout_diagnostics(rtype, name)
        raise

runner.poll_until = _instrumented_poll_until
PATCHEOF

echo "Running vmaas tests..."
podman run --authfile /root/pull-secret --rm --network=host \
    -v "${KUBECONFIG_PATH}":/root/.kube/config:z \
    -v /root/pull-secret:/root/pull-secret:z \
    -v "${RESULTS_DIR}":/tmp/test-results:z \
    -v /tmp/patch_helpers.py:/tmp/patch_helpers.py:z \
    -e KUBECONFIG=/root/.kube/config \
    -e OSAC_VM_KUBECONFIG=/root/.kube/config \
    -e OSAC_NAMESPACE="${NAMESPACE}" \
    -e OSAC_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e OSAC_CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE}" \
    -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
    "${TEST_IMAGE}" \
    bash -c "cat /tmp/patch_helpers.py >> tests/conftest.py && pytest tests/vmaas/ -v --junitxml=/tmp/test-results/junit_vmaas.xml"

echo "Tests completed."
REMOTE_EOF

if [[ "${TEST_EXIT}" -ne 0 ]]; then
    echo "Some tests failed (exit code: ${TEST_EXIT})"
    exit "${TEST_EXIT}"
fi

echo "All tests passed."
