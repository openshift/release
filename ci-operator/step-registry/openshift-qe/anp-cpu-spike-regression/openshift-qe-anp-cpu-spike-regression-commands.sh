#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

MONITOR_DURATION=${MONITOR_DURATION:-1200}
ANP_COUNT=${ANP_COUNT:-70}
TEST_LABEL="anp-cpu-spike-test"

cleanup() {
    echo "--- Cleanup ---"
    oc delete cronjobs -A -l "app=${TEST_LABEL}" --wait=false 2>/dev/null || true
    sleep 5
    oc delete anp -l "${TEST_LABEL}=true" --wait=false 2>/dev/null || true
    oc delete banp default --wait=false 2>/dev/null || true
    for i in $(seq 1 "${ANP_COUNT}"); do
        oc delete namespace "${TEST_LABEL}-ns-${i}" --wait=false 2>/dev/null || true
    done
    echo "Cleanup initiated."
}
trap cleanup EXIT

echo "=== ANP CPU Spike Regression Test ==="
echo "Bug chain: OCPBUGS-62895 / 85366 / 98616 / 105851"
echo "Fix: doesStatusNeedAnUpdate() skips redundant ANP/BANP status patches"
echo "ANPs: ${ANP_COUNT}  Monitor: ${MONITOR_DURATION}s"
echo ""

# --- Step 1: Namespaces ---
echo "Creating ${ANP_COUNT} namespaces..."
for i in $(seq 1 "${ANP_COUNT}"); do
    NS="anp-cpu-spike-test-ns-${i}"
    TEAM_ID=$(( (i % 5) + 1 ))
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    ${TEST_LABEL}: "true"
    team: "team-${TEAM_ID}"
EOF
done
echo "Created ${ANP_COUNT} namespaces."

# --- Step 2: BANP ---
echo "Creating BANP..."
oc apply -f - >/dev/null <<'EOF'
apiVersion: policy.networking.k8s.io/v1alpha1
kind: BaselineAdminNetworkPolicy
metadata:
  name: default
spec:
  subject:
    namespaces:
      matchLabels:
        anp-cpu-spike-test: "true"
  ingress:
  - name: deny-all-ingress
    action: Deny
    from:
    - namespaces: {}
  egress:
  - name: allow-dns
    action: Allow
    to:
    - namespaces:
        matchLabels:
          kubernetes.io/metadata.name: openshift-dns
    ports:
    - portNumber:
        protocol: UDP
        port: 53
  - name: allow-kube-system
    action: Allow
    to:
    - namespaces:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
  - name: deny-other-egress
    action: Deny
    to:
    - namespaces: {}
EOF
echo "Created BANP."

# --- Step 3: ANPs ---
echo "Creating ${ANP_COUNT} ANPs..."
for i in $(seq 1 "${ANP_COUNT}"); do
    NS="anp-cpu-spike-test-ns-${i}"
    PRIORITY=$(( 100 + i ))
    oc apply -f - >/dev/null <<EOF
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: anp-cpu-spike-test-${i}
  labels:
    anp-cpu-spike-test: "true"
spec:
  priority: ${PRIORITY}
  subject:
    namespaces:
      matchLabels:
        kubernetes.io/metadata.name: ${NS}
  ingress:
  - name: allow-from-same-ns
    action: Allow
    from:
    - namespaces:
        matchLabels:
          kubernetes.io/metadata.name: ${NS}
  - name: pass-other
    action: Pass
    from:
    - namespaces: {}
  egress:
  - name: allow-dns
    action: Allow
    to:
    - namespaces:
        matchLabels:
          kubernetes.io/metadata.name: openshift-dns
    ports:
    - portNumber:
        protocol: UDP
        port: 53
  - name: pass-other-egress
    action: Pass
    to:
    - namespaces: {}
EOF
done
echo "Created ${ANP_COUNT} ANPs."

# --- Step 4: CronJobs (2 per namespace, every 5 min) ---
CRONJOB_COUNT=$(( ANP_COUNT * 2 ))
echo "Creating ${CRONJOB_COUNT} CronJobs..."
for i in $(seq 1 "${ANP_COUNT}"); do
    NS="anp-cpu-spike-test-ns-${i}"
    for j in 1 2; do
        oc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: anp-spike-cj-${j}
  namespace: ${NS}
  labels:
    app: ${TEST_LABEL}
spec:
  schedule: "*/5 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 60
      template:
        metadata:
          labels:
            app: ${TEST_LABEL}
        spec:
          restartPolicy: Never
          containers:
          - name: workload
            image: registry.access.redhat.com/ubi9/ubi-minimal:latest
            command: ["/bin/sh", "-c", "sleep 10"]
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                cpu: 50m
                memory: 64Mi
EOF
    done
done
echo "Created ${CRONJOB_COUNT} CronJobs."

# --- Locate ovnkube-controller pod ---
OVN_POD=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${OVN_POD}" ]]; then
    echo "ERROR: Could not find ovnkube-node pod"
    exit 1
fi
echo "ovnkube pod: ${OVN_POD}"

echo ""
echo "Waiting 5 minutes for first CronJob trigger cycle..."
sleep 300

# --- Step 5: Monitor ---
echo ""
echo "=== Monitoring for ${MONITOR_DURATION}s ==="
START_TIME=$(date +%s)
ITERATION=1
TOTAL_PATCH_COUNT=0

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    [[ ${ELAPSED} -ge ${MONITOR_DURATION} ]] && break

    TS=$(date '+%H:%M:%S')
    PATCH_COUNT=$(oc logs -n openshift-ovn-kubernetes "${OVN_POD}" \
        -c ovnkube-controller --since=30s 2>/dev/null \
        | grep -c "Patched status" || true)
    RECON_COUNT=$(oc logs -n openshift-ovn-kubernetes "${OVN_POD}" \
        -c ovnkube-controller --since=30s 2>/dev/null \
        | grep -c "admin_network_policy" || true)

    TOTAL_PATCH_COUNT=$(( TOTAL_PATCH_COUNT + PATCH_COUNT ))

    echo "[${ITERATION}] ${TS} elapsed=${ELAPSED}s  patch_calls=${PATCH_COUNT}  anp_recon=${RECON_COUNT}  cumulative_patches=${TOTAL_PATCH_COUNT}"

    sleep 30
    ITERATION=$(( ITERATION + 1 ))
done

echo ""
echo "=== Result ==="
echo "Total monitoring iterations: ${ITERATION}"
echo "Total 'Patched status' calls observed: ${TOTAL_PATCH_COUNT}"
echo ""

if [[ ${TOTAL_PATCH_COUNT} -eq 0 ]]; then
    echo "PASS: No redundant status patches detected. Fix is working correctly."
    exit 0
else
    echo "FAIL: ${TOTAL_PATCH_COUNT} redundant 'Patched status' calls detected."
    echo "      The fix (doesStatusNeedAnUpdate) is not preventing unnecessary patches."
    exit 1
fi
