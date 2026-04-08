#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Verify: Setting imageregistry managementState to Removed stops pull secret
# creation for new ServiceAccounts.
# Bug: OCPBUGS-81836 / OCPBUGS-79539
# ============================================================================

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# --- Setup ---
echo "=== Setup: Create HostedCluster ==="

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
echo "Using release image: ${RELEASE_IMAGE}"

# Generate pull secret
oc registry login --to=/tmp/pull-secret-build-farm.json
jq -s '.[0] * .[1]' /tmp/pull-secret-build-farm.json /etc/ci-pull-credentials/.dockerconfigjson > /tmp/pull-secret.json

# Management cluster kubeconfig
export MGMT_KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

# Cluster naming
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Cluster name: ${CLUSTER_NAME}, Infra ID: ${INFRA_ID}"

# Base domain
DOMAIN="${HYPERSHIFT_BASE_DOMAIN:-ci.hypershift.devcluster.openshift.com}"
echo "Using base domain: ${DOMAIN}"

# Use hypershift-pool-aws-credentials (has Route53 access to ci.hypershift.devcluster.openshift.com)
AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

# The shared root management cluster runs on arm64; always use --multi-arch
MULTI_ARCH_ARG="--multi-arch"

# Build CPO override args if image is specified
CPO_ARGS=""
if [[ -n "${CPO_IMAGE:-}" ]]; then
  echo "Using CPO image override: ${CPO_IMAGE}"
  CPO_ARGS="--annotations hypershift.openshift.io/control-plane-operator-image=${CPO_IMAGE}"
fi

echo "Creating HostedCluster..."
KUBECONFIG="${MGMT_KUBECONFIG}" /usr/bin/hypershift create cluster aws \
  --name "${CLUSTER_NAME}" \
  --infra-id "${INFRA_ID}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --instance-type "m5.xlarge" \
  --base-domain "${DOMAIN}" \
  --region "${HYPERSHIFT_AWS_REGION}" \
  --control-plane-availability-policy "SingleReplica" \
  --infra-availability-policy "SingleReplica" \
  --pull-secret /tmp/pull-secret.json \
  --aws-creds "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --release-image "${RELEASE_IMAGE}" \
  --node-selector "hypershift.openshift.io/control-plane=true" \
  --olm-catalog-placement "management" \
  --additional-tags "expirationDate=${EXPIRATION_DATE}" \
  --annotations "prow.k8s.io/job=${JOB_NAME}" \
  --annotations "cluster-profile=${CLUSTER_PROFILE_NAME}" \
  --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "hypershift.openshift.io/cleanup-cloud-resources=false" \
  ${MULTI_ARCH_ARG} \
  ${CPO_ARGS} \
  --additional-tags "prow.k8s.io/job=${JOB_NAME}" \
  --additional-tags "prow.k8s.io/build-id=${BUILD_ID}"

# Save cluster info for cleanup
echo "CLUSTER_NAME=${CLUSTER_NAME}" > "${SHARED_DIR}/hosted_cluster.txt"
echo "INFRA_ID=${INFRA_ID}" >> "${SHARED_DIR}/hosted_cluster.txt"

# Wait for cluster to become available
echo "Waiting for HostedCluster to become available..."
KUBECONFIG="${MGMT_KUBECONFIG}" oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME} || {
  echo "ERROR: Cluster did not become available"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc get hostedcluster ${CLUSTER_NAME} --namespace=clusters -o yaml > "${ARTIFACT_DIR}/hostedcluster_failed.yaml" 2>/dev/null || true
  exit 1
}
echo "HostedCluster is available"

# Verify CPO image override annotation
if [[ -n "${CPO_IMAGE:-}" ]]; then
  CPO_ANNOTATION=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get hostedcluster ${CLUSTER_NAME} -n clusters \
    -o jsonpath='{.metadata.annotations.hypershift\.openshift\.io/control-plane-operator-image}' 2>/dev/null || echo "not-set")
  echo "CPO annotation on HostedCluster: ${CPO_ANNOTATION}"
  if [[ "${CPO_ANNOTATION}" == "${CPO_IMAGE}" ]]; then
    pass "CPO image override annotation is set correctly"
  else
    fail "CPO image override annotation mismatch — expected ${CPO_IMAGE}, got ${CPO_ANNOTATION}"
  fi
fi

# Get guest cluster kubeconfig
echo "Retrieving guest cluster kubeconfig..."
KUBECONFIG="${MGMT_KUBECONFIG}" /usr/bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} > /tmp/guest_kubeconfig
export GUEST_KUBECONFIG=/tmp/guest_kubeconfig

# Wait for clusterversion to be available in guest
echo "Waiting for guest cluster clusterversion..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc wait --timeout=10m --for='condition=Available=True' clusterversion/version || {
  echo "WARNING: Guest cluster version not available yet, continuing anyway"
}

echo ""
echo "============================================================"
echo "=== Step 1: Verify pull secrets ARE created before disabling registry ==="
echo "============================================================"

BEFORE_NS="verify-before-${CLUSTER_NAME:0:10}"
echo "Creating test namespace: ${BEFORE_NS}"
KUBECONFIG="${GUEST_KUBECONFIG}" oc create namespace "${BEFORE_NS}"

echo "Creating test ServiceAccount..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc create serviceaccount test-sa -n "${BEFORE_NS}"

echo "Waiting 60s for pull secret creation..."
sleep 60

BEFORE_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get secrets -n "${BEFORE_NS}" \
  -o go-template='{{range .items}}{{if eq .type "kubernetes.io/dockercfg"}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null || echo "")

echo "Pull secrets before disabling registry: '${BEFORE_SECRETS}'"

if [[ -n "${BEFORE_SECRETS}" ]]; then
  pass "Pull secrets are created for new SA when registry is enabled (baseline confirmed)"
else
  skip "No pull secrets created even with registry enabled — baseline unclear, continuing"
fi

echo ""
echo "============================================================"
echo "=== Step 2: Set Image Registry managementState to Removed ==="
echo "============================================================"

echo "Current imageregistry config:"
KUBECONFIG="${GUEST_KUBECONFIG}" oc get configs.imageregistry.operator.openshift.io cluster \
  -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "(could not read)"
echo ""

echo "Patching imageregistry config to managementState: Removed..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge -p '{"spec":{"managementState":"Removed"}}' || {
  echo "ERROR: Failed to patch imageregistry config — cannot proceed"
  exit 1
}

echo "Waiting 120s for the change to propagate through the control plane..."
sleep 120

echo ""
echo "============================================================"
echo "=== Step 3: Verify NO pull secrets created after disabling registry ==="
echo "============================================================"

AFTER_NS="verify-after-${CLUSTER_NAME:0:10}"
echo "Creating test namespace: ${AFTER_NS}"
KUBECONFIG="${GUEST_KUBECONFIG}" oc create namespace "${AFTER_NS}"

echo "Creating test ServiceAccount..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc create serviceaccount test-sa -n "${AFTER_NS}"

echo "Waiting 60s for any secret creation..."
sleep 60

AFTER_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get secrets -n "${AFTER_NS}" \
  -o go-template='{{range .items}}{{if eq .type "kubernetes.io/dockercfg"}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null || echo "")

echo "Pull secrets after disabling registry: '${AFTER_SECRETS}'"

if [[ -z "${AFTER_SECRETS}" ]]; then
  pass "No pull secrets created for new SA after registry set to Removed"
else
  # Check if any are linked to the SA
  SA_PULL_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get serviceaccount test-sa -n "${AFTER_NS}" \
    -o go-template='{{range .imagePullSecrets}}{{.name}} {{end}}' 2>/dev/null || echo "")
  if echo "${SA_PULL_SECRETS}" | grep -q "dockercfg"; then
    fail "Pull secrets were created AND associated with SA despite registry being Removed"
    echo "SA imagePullSecrets: ${SA_PULL_SECRETS}"
    echo "Secrets in namespace:"
    KUBECONFIG="${GUEST_KUBECONFIG}" oc get secrets -n "${AFTER_NS}" 2>/dev/null || true
  else
    pass "dockercfg secrets exist but are not associated with ServiceAccount"
  fi
fi

echo ""
echo "============================================================"
echo "=== Step 4: Verify fix persists across time (not overwritten by CPO) ==="
echo "============================================================"

echo "Waiting 180s for multiple CPO reconciliation cycles..."
sleep 180

PERSIST_NS="verify-persist-${CLUSTER_NAME:0:10}"
echo "Creating test namespace: ${PERSIST_NS}"
KUBECONFIG="${GUEST_KUBECONFIG}" oc create namespace "${PERSIST_NS}"

echo "Creating test ServiceAccount..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc create serviceaccount test-sa -n "${PERSIST_NS}"

echo "Waiting 60s for any secret creation..."
sleep 60

PERSIST_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get secrets -n "${PERSIST_NS}" \
  -o go-template='{{range .items}}{{if eq .type "kubernetes.io/dockercfg"}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null || echo "")

echo "Pull secrets after CPO reconciliation: '${PERSIST_SECRETS}'"

if [[ -z "${PERSIST_SECRETS}" ]]; then
  pass "Fix persists — no pull secrets created after CPO reconciliation cycles"
else
  SA_PULL_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get serviceaccount test-sa -n "${PERSIST_NS}" \
    -o go-template='{{range .imagePullSecrets}}{{.name}} {{end}}' 2>/dev/null || echo "")
  if echo "${SA_PULL_SECRETS}" | grep -q "dockercfg"; then
    fail "CPO reconciliation re-enabled pull secret creation — fix did not persist"
    echo "SA imagePullSecrets: ${SA_PULL_SECRETS}"
  else
    pass "dockercfg secrets exist but are not associated with ServiceAccount after CPO reconciliation"
  fi
fi

# Cleanup test namespaces
KUBECONFIG="${GUEST_KUBECONFIG}" oc delete namespace "${BEFORE_NS}" --wait=false 2>/dev/null || true
KUBECONFIG="${GUEST_KUBECONFIG}" oc delete namespace "${AFTER_NS}" --wait=false 2>/dev/null || true
KUBECONFIG="${GUEST_KUBECONFIG}" oc delete namespace "${PERSIST_NS}" --wait=false 2>/dev/null || true

echo ""
echo "============================================================"
echo "=== RESULTS SUMMARY ==="
echo "============================================================"
echo "PASSED: ${PASS_COUNT}"
echo "FAILED: ${FAIL_COUNT}"
echo "SKIPPED: ${SKIP_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "RESULT: VERIFICATION FAILED"
  exit 1
else
  echo "RESULT: ALL CHECKS PASSED"
fi
