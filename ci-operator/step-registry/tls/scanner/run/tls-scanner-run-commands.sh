#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# TLS Scanner - scans TLS configurations of all pods in the cluster
NAMESPACE="tls-scanner"
SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"

# Determine scanner arguments based on whether a specific namespace is requested
if [[ -n "${SCAN_NAMESPACE:-}" ]]; then
    SCANNER_ARGS="--all-pods --namespace-filter ${SCAN_NAMESPACE}"
else
    SCANNER_ARGS="--all-pods"
fi

# Enable post-quantum cryptography checks when requested by the step ref.
if [[ "${PQC_CHECK:-false}" == "true" ]]; then
    SCANNER_ARGS="${SCANNER_ARGS} --pqc-check"
    echo "PQC readiness mode enabled: checks TLS 1.3 support and mlkem or mlkem25519 support per target."
fi

if [[ -n "${SCAN_LIMIT_IPS:-}" && "${SCAN_LIMIT_IPS}" != "0" ]]; then
    SCANNER_ARGS="${SCANNER_ARGS} --limit-ips ${SCAN_LIMIT_IPS}"
    echo "Limiting scan to ${SCAN_LIMIT_IPS} IPs (smoke testing)."
fi

mkdir -p "${SCANNER_ARTIFACT_DIR}"

echo "=== TLS Scanner ==="
echo "Image: ${SCANNER_IMAGE}"

# Create namespace
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Cleanup on exit
cleanup() {
    echo "Cleaning up..."
    oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false || true
}
trap cleanup EXIT

# Grant cluster-admin to the default service account for full access
oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${NAMESPACE}"

# Grant privileged SCC to the service account (required for hostNetwork, hostPID, privileged container)
oc adm policy add-scc-to-user privileged -z default -n "${NAMESPACE}"

# Wait for RBAC/SCC changes to propagate before creating the pod
# This ensures the SCC admission controller sees the new binding
echo "Waiting for RBAC/SCC changes to propagate..."
sleep 10

# Create the scanner pod with privileged access
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: default
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
  - name: scanner
    image: ${SCANNER_IMAGE}
    command:
    - /bin/bash
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner -j 4 ${SCANNER_ARGS} \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --junit-file /results/junit_tls_scan.xml \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      SCAN_EXIT_CODE=\${PIPESTATUS[0]}
      echo "Scan complete. Exit code: \${SCAN_EXIT_CODE}" | tee -a /results/output.log
      touch /results/scan.done
      # Keep pod alive for artifact collection
      sleep 120
      # We are intentionally ignoring the scanner exit code for the moment
      # exit \${SCAN_EXIT_CODE}
    resources:
      requests:
        cpu: "${SCANNER_CPU}"
        memory: ${SCANNER_MEMORY}
      limits:
        cpu: "${SCANNER_CPU}"
        memory: ${SCANNER_MEMORY}
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    emptyDir: {}
EOF

echo "Waiting for scanner pod to start..."
oc wait --for=condition=Ready pod/tls-scanner -n "${NAMESPACE}" --timeout=5m || {
    echo "Pod failed to start:"
    oc describe pod/tls-scanner -n "${NAMESPACE}"
    oc get events -n "${NAMESPACE}"
    exit 1
}

echo "Streaming scanner logs (live)..."
oc logs -f pod/tls-scanner -n "${NAMESPACE}" &
LOGS_PID=$!

echo "Waiting for scan to finish (pod stays alive 120s after scan for artifact collection)..."
while true; do
    phase=$(oc get pod/tls-scanner -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "Poll: phase=${phase}"
    # Scanner completion check first — must copy artifacts while pod is still running.
    if oc exec pod/tls-scanner -n "${NAMESPACE}" -- test -f /results/scan.done 2>/dev/null; then
        echo "/results/scan.done found — proceeding to copy artifacts"
        break
    fi
    # Fallback: pod already exited (sleep window expired or crash).
    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
        echo "Warning: pod ${phase} before artifact collection — oc cp will likely fail"
        break
    fi
    sleep 15
done

echo "Copying artifacts..."
oc cp "${NAMESPACE}/tls-scanner:/results/." "${SCANNER_ARTIFACT_DIR}/" || echo "Warning: Failed to copy some artifacts"

if [[ -f "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" ]]; then
    cp "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" "${ARTIFACT_DIR}/junit_tls_scan.xml"
    echo "JUnit results copied to ${ARTIFACT_DIR}/junit_tls_scan.xml for Spyglass"
fi

wait $LOGS_PID 2>/dev/null || true

if [[ "$(oc get pod/tls-scanner -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Failed" ]]; then
    echo "Scanner pod failed"
    oc describe pod/tls-scanner -n "${NAMESPACE}"
    exit 1
fi

oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/tls-scanner -n "${NAMESPACE}" --timeout=10m || {
    echo "Scanner did not complete successfully - timeout exceeded"
    oc describe pod/tls-scanner -n "${NAMESPACE}"
    exit 1
}

echo "=== TLS Scanner Complete ==="
echo "Artifacts saved to: ${SCANNER_ARTIFACT_DIR}"
ls -la "${SCANNER_ARTIFACT_DIR}" || true
