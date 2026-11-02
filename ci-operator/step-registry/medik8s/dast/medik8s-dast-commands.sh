#!/bin/bash
set -eu -o pipefail
# shellcheck source=/dev/null
source "${SHARED_DIR}/medik8s-lib.sh" || {
    echo "ERROR: medik8s-lib.sh not found in SHARED_DIR." >&2
    echo "Include the medik8s-setup chain before this step." >&2
    exit 1
}

declare RHWA_NAMESPACE="${RHWA_NAMESPACE:-openshift-workload-availability}"
declare TRIVY_IMAGE="${TRIVY_IMAGE:-docker.io/aquasec/trivy:0.76.1}"

DAST_NS="rhwa-dast-scan"
JOB_NAME="trivy-dast"
NAMESPACE_CREATED=false

collect_artifacts() {
    log "Collecting DAST artifacts..."
    {
        # Capture pod details before they are lost to namespace deletion
        oc describe pod -l job-name="$JOB_NAME" -n "$DAST_NS" 2>&1 | tee "${ARTIFACT_DIR}/dast-pod-describe.txt" || true
        oc get pod -l job-name="$JOB_NAME" -n "$DAST_NS" -o yaml > "${ARTIFACT_DIR}/dast-pod.yaml" 2>&1 || true
        oc get job "$JOB_NAME" -n "$DAST_NS" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/dast-job.yaml" || true
        oc logs job/"$JOB_NAME" -n "$DAST_NS" 2>/dev/null \
            > "${ARTIFACT_DIR}/dast-scan-output.json" || true
        oc get events -n "$DAST_NS" --sort-by='.lastTimestamp' 2>/dev/null \
            > "${ARTIFACT_DIR}/dast-events.txt" || true
    } || true
}

cleanup() {
    collect_artifacts
    log "Cleaning up DAST cluster-scoped RBAC..."
    oc delete clusterrolebinding "trivy-scanner-${DAST_NS}" --ignore-not-found || true
    oc delete clusterrole trivy-pod-reader --ignore-not-found || true
    # Only delete the namespace if this run created it to avoid removing a pre-existing namespace.
    if [[ "$NAMESPACE_CREATED" == "true" ]]; then
        oc delete namespace "$DAST_NS" --ignore-not-found --timeout=60s || true
    fi
}
trap cleanup EXIT

log "DAST scan: namespace=${RHWA_NAMESPACE} image=${TRIVY_IMAGE}"

# Create isolated namespace for the scan job
if run oc create namespace "$DAST_NS"; then
    NAMESPACE_CREATED=true
fi

# Create a scoped read-only service account for the scanner.
# This avoids mounting the broad CI kubeconfig into the scan Job.
run oc create serviceaccount trivy-scanner -n "$DAST_NS"
run oc create clusterrole trivy-pod-reader \
    --verb=get,list,watch \
    --resource=pods,nodes,namespaces,events
run oc create clusterrolebinding "trivy-scanner-${DAST_NS}" \
    --clusterrole=trivy-pod-reader \
    --serviceaccount="${DAST_NS}:trivy-scanner"

# Preflight: verify the scanner identity (not the CI identity) can list pods.
# The CI identity always has access; this tests the RBAC we just created.
log "Verifying scanner pod-list access in ${RHWA_NAMESPACE}..."
if ! oc auth can-i list pods -n "$RHWA_NAMESPACE" \
        --as="system:serviceaccount:${DAST_NS}:trivy-scanner" >/dev/null 2>&1; then
    log "ERROR: trivy-scanner cannot list pods in ${RHWA_NAMESPACE}. Trivy would silently skip pods."
    exit 1
fi

log "Verifying pods exist in ${RHWA_NAMESPACE}..."
if [[ -z "$(oc get pods -n "$RHWA_NAMESPACE" -o name 2>/dev/null)" ]]; then
    log "ERROR: No pods found in ${RHWA_NAMESPACE}. The scan would cover nothing."
    exit 1
fi

# Generate a scoped kubeconfig from the SA token and the current cluster endpoint.
# Write to a temp file so the token is not exposed through the run() helper's command logging.
CLUSTER_SERVER=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SA_TOKEN=$(oc create token trivy-scanner -n "$DAST_NS" --duration=1h)
kubeconfig_file=$(mktemp)
cat > "${kubeconfig_file}" <<KUBE
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${CLUSTER_CA}
  name: scan-cluster
contexts:
- context:
    cluster: scan-cluster
    namespace: ${RHWA_NAMESPACE}
    user: trivy-scanner
  name: scan-context
current-context: scan-context
users:
- name: trivy-scanner
  user:
    token: ${SA_TOKEN}
KUBE
oc create secret generic trivy-kubeconfig \
    -n "$DAST_NS" \
    --from-file=kubeconfig="${kubeconfig_file}"
rm -f "${kubeconfig_file}"

# Create the scan Job
cat <<EOF | run oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${DAST_NS}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: trivy
        image: ${TRIVY_IMAGE}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        env:
        - name: TRIVY_CACHE_DIR
          value: /trivy-cache
        - name: KUBECONFIG
          value: /kubeconfig/kubeconfig
        volumeMounts:
        - name: kubeconfig
          mountPath: /kubeconfig
          readOnly: true
        - name: trivy-cache
          mountPath: /trivy-cache
        - name: tmp
          mountPath: /tmp
        args:
        - k8s
        - --include-namespaces
        - ${RHWA_NAMESPACE}
        - --include-kinds
        - Pod
        - --disable-node-collector
        - --severity=HIGH,CRITICAL
        - --scanners=misconfig
        - --report
        - all
        - --format
        - json
        - --exit-code
        - "1"
        resources:
          requests:
            cpu: 500m
            memory: 500Mi
          limits:
            cpu: "2"
            memory: 1Gi
      volumes:
      - name: kubeconfig
        secret:
          secretName: trivy-kubeconfig
      - name: trivy-cache
        emptyDir: {}
      - name: tmp
        emptyDir: {}
EOF

# Start the scan deadline before following logs to enforce the 600s limit end-to-end.
deadline=$((SECONDS + 600))

log "Streaming DAST scan output..."
remaining=$((deadline - SECONDS))
if (( remaining > 0 )); then
    timeout "${remaining}s" oc logs job/"$JOB_NAME" -n "$DAST_NS" -f 2>/dev/null || true
fi

# Poll for Complete or Failed — oc wait --for=condition=Complete alone blocks the full
# timeout when the Job fails (findings found), giving a misleading 10-minute delay.
log "Waiting for DAST job to complete (max 600s)..."
job_state=""
while (( SECONDS < deadline )); do
    if [[ "$(oc get job "$JOB_NAME" -n "$DAST_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]]; then
        job_state=complete; break
    fi
    if [[ "$(oc get job "$JOB_NAME" -n "$DAST_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')" == "True" ]]; then
        job_state=failed; break
    fi
    sleep 10
done

# Check once more after deadline for Job condition propagation (avoid race near deadline).
if [[ "$job_state" == "" ]]; then
    sleep 5
    if [[ "$(oc get job "$JOB_NAME" -n "$DAST_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]]; then
        job_state=complete
    elif [[ "$(oc get job "$JOB_NAME" -n "$DAST_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')" == "True" ]]; then
        job_state=failed
    fi
fi

if [[ "$job_state" != "complete" ]]; then
    log "ERROR: DAST job ended with state '${job_state:-timeout}' (findings or scan error)"
    oc get job "$JOB_NAME" -n "$DAST_NS" -o jsonpath='{.status}' | python3 -m json.tool || true
    exit 1
fi

log "DAST scan completed — no HIGH/CRITICAL misconfigurations found."
