#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

NAMESPACE="tls-scanner"
SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"

mkdir -p "${SCANNER_ARTIFACT_DIR}"

echo "=== TLS Scanner ==="
echo "Image: ${SCANNER_IMAGE}"

oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

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
    - /bin/sh
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner --all-pods \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      echo "Scan complete. Exit code: \$?"
      # Keep pod alive for artifact collection
      sleep 120
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

echo "Waiting for scan to complete..."
while true; do
    if oc logs pod/tls-scanner -n "${NAMESPACE}" 2>/dev/null | grep -q "Scan complete"; then
        break
    fi
    echo "  Scan still running..."
    sleep 30
done

echo "Scan completed. Fetching full logs..."
oc logs pod/tls-scanner -n "${NAMESPACE}" || true

echo "Copying artifacts (container still alive in sleep phase)..."
oc cp "${NAMESPACE}/tls-scanner:/results/." "${SCANNER_ARTIFACT_DIR}/" || echo "Warning: Failed to copy some artifacts"

# Wait for pod to complete
oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/tls-scanner -n "${NAMESPACE}" --timeout=4h || {
    echo "Scanner did not complete successfully"
    oc describe pod/tls-scanner -n "${NAMESPACE}"
    exit 1
}

echo "=== TLS Scanner Complete ==="
echo "Artifacts saved to: ${SCANNER_ARTIFACT_DIR}"
ls -la "${SCANNER_ARTIFACT_DIR}" || true
