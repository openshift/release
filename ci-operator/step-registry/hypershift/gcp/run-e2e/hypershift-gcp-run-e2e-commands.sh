#!/usr/bin/env bash

set -euo pipefail

# This step runs e2e tests against a HyperShift Control Plane cluster on GKE

echo "Starting HyperShift GCP e2e tests..."

# The kubeconfig from hypershift-gcp-gke-provision uses a static access token,
# so no gcloud/auth-plugin installation is needed here.

# =============================================================================
# TODO(GCP-295): Remove this block after GCP platform support is merged
# =============================================================================
# This is a TEMPORARY WORKAROUND during GCP e2e development.
# The official hypershift-tests image doesn't have GCP platform flags yet.
# We extract a custom test binary that includes GCP support.
#
# CLEANUP: Once https://github.com/openshift/hypershift/pull/7697 (GCP-295) merges:
# 1. Remove lines 12-32 (this extraction block)
# 2. Remove lines 138-159 (the E2E_TEST_BIN execution block)
# 3. Keep only the hack/ci-test-e2e.sh path (lines 160-180)
# =============================================================================
GCP_TEST_IMAGE="quay.io/cveiga/hypershift:GCP-295-e2e-gcp-platform-support-4f9d5c16-test"
echo "Extracting e2e test binary from ${GCP_TEST_IMAGE}..."
mkdir -p /tmp/hypershift-tests
oc image extract "${GCP_TEST_IMAGE}" \
    --path /hypershift/bin/test-e2e:/tmp/hypershift-tests \
    --registry-config=/etc/ci-pull-credentials/.dockerconfigjson \
    --filter-by-os="linux/amd64" || true
if [[ -f /tmp/hypershift-tests/test-e2e ]]; then
    chmod +x /tmp/hypershift-tests/test-e2e
    export E2E_TEST_BIN="/tmp/hypershift-tests/test-e2e"
    echo "Using extracted e2e test binary: ${E2E_TEST_BIN}"
else
    echo "Failed to extract e2e test binary, using default from image"
    export E2E_TEST_BIN=""
fi

# Load kubeconfig for the Control Plane cluster
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "ERROR: Control Plane cluster kubeconfig not found"
    exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Load GCP configuration from provision steps
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
CP_PROJECT_ID="$(<"${SHARED_DIR}/control-plane-project-id")"
HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"
# The PSC subnet for the consumer endpoint must be in the HC project.
# The operator auto-discovers the service attachment subnet on the CP side.
PSC_SUBNET="$(<"${SHARED_DIR}/hc-subnet-name")"
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"

# Construct base domain for hosted clusters (from workflow env var)
BASE_DOMAIN="in.${CLUSTER_NAME}.${HYPERSHIFT_GCP_CI_DNS_DOMAIN}"

# Load HC-specific infrastructure (from hypershift-gcp-hosted-cluster-setup step)
# Use HC-specific VPC if available, otherwise fall back to Control Plane VPC
if [[ -f "${SHARED_DIR}/hc-vpc-name" ]]; then
    VPC_NAME="$(<"${SHARED_DIR}/hc-vpc-name")"
else
    VPC_NAME="$(<"${SHARED_DIR}/vpc-name")"
fi

# Load WIF configuration (from hypershift-gcp-hosted-cluster-setup step)
WIF_PROJECT_NUMBER=""
WIF_POOL_ID=""
WIF_PROVIDER_ID=""
NODEPOOL_SA=""
CONTROLPLANE_SA=""
CLOUDCONTROLLER_SA=""
SA_SIGNING_KEY_PATH=""

if [[ -f "${SHARED_DIR}/wif-project-number" ]]; then
    WIF_PROJECT_NUMBER="$(<"${SHARED_DIR}/wif-project-number")"
fi
if [[ -f "${SHARED_DIR}/wif-pool-id" ]]; then
    WIF_POOL_ID="$(<"${SHARED_DIR}/wif-pool-id")"
fi
if [[ -f "${SHARED_DIR}/wif-provider-id" ]]; then
    WIF_PROVIDER_ID="$(<"${SHARED_DIR}/wif-provider-id")"
fi
if [[ -f "${SHARED_DIR}/nodepool-sa" ]]; then
    NODEPOOL_SA="$(<"${SHARED_DIR}/nodepool-sa")"
fi
if [[ -f "${SHARED_DIR}/controlplane-sa" ]]; then
    CONTROLPLANE_SA="$(<"${SHARED_DIR}/controlplane-sa")"
fi
if [[ -f "${SHARED_DIR}/cloudcontroller-sa" ]]; then
    CLOUDCONTROLLER_SA="$(<"${SHARED_DIR}/cloudcontroller-sa")"
fi
if [[ -f "${SHARED_DIR}/storage-sa" ]]; then
    STORAGE_SA="$(<"${SHARED_DIR}/storage-sa")"
fi
if [[ -f "${SHARED_DIR}/sa-signing-key-path" ]]; then
    SA_SIGNING_KEY_PATH="$(<"${SHARED_DIR}/sa-signing-key-path")"
fi

set -x

# Verify HyperShift operator is running
echo "=== Verifying HyperShift Operator ==="
oc wait --for=condition=Available deployment/operator -n hypershift --timeout=300s

# Check HyperShift CRDs are installed
echo "=== Checking HyperShift CRDs ==="
oc get crd hostedclusters.hypershift.openshift.io
oc get crd nodepools.hypershift.openshift.io

# Verify no HyperShift pods are in error state
echo "=== Checking HyperShift Pod Health ==="
UNHEALTHY_PODS=$(oc get pods -n hypershift --no-headers | grep -v -E "Running|Completed" | wc -l || true)
if [[ "${UNHEALTHY_PODS}" -gt 0 ]]; then
    echo "WARNING: Found ${UNHEALTHY_PODS} unhealthy pods in hypershift namespace"
    oc get pods -n hypershift
fi

# Basic connectivity test
echo "=== Testing Cluster Connectivity ==="
oc cluster-info
oc get nodes -o wide

# Check if we have WIF configuration for full e2e tests
if [[ -z "${WIF_PROJECT_NUMBER}" || -z "${WIF_POOL_ID}" || -z "${WIF_PROVIDER_ID}" ]]; then
    echo "=== WIF configuration not available, running basic validation only ==="
    echo "To run full e2e tests, ensure hypershift-gcp-hosted-cluster-setup step has run"
    echo "before this step to create WIF infrastructure."

    echo ""
    echo "=== Basic Validation Complete ==="
    echo "HyperShift operator is running and CRDs are installed"
    echo "GCP Region: ${GCP_REGION}"
    echo "Control Plane Project: ${CP_PROJECT_ID}"
    echo "Hosted Cluster Project: ${HC_PROJECT_ID}"
    exit 0
fi

# Validate SA signing key is available
if [[ -z "${SA_SIGNING_KEY_PATH}" || ! -s "${SA_SIGNING_KEY_PATH}" ]]; then
    echo "ERROR: SA signing key not found or empty at ${SA_SIGNING_KEY_PATH}"
    echo "Ensure hypershift-gcp-hosted-cluster-setup step has run"
    exit 1
fi

echo "=== Running e2e tests with GCP platform ==="

# Run the e2e tests
# Use CI_TESTS_RUN to filter which tests to run (default: TestCreateCluster)
export EVENTUALLY_VERBOSE="false"

# Construct OIDC issuer URL (matches pattern used by hypershift create iam gcp)
OIDC_ISSUER_URL="https://hypershift-${CLUSTER_NAME}-oidc"

# TODO(GCP-295): Remove this if-block after GCP platform support merges (see comment at top)
if [[ -n "${E2E_TEST_BIN:-}" && -x "${E2E_TEST_BIN}" ]]; then
    echo "Running e2e tests using extracted binary: ${E2E_TEST_BIN}"
    # TODO(GCP-295): Remove CPO image override after multizone fix is merged
    CPO_IMAGE="quay.io/cveiga/hypershift:GCP-295-e2e-gcp-platform-support-4f9d5c16"
    # TODO(GCP-426): Remove CAPG image override once HyperShift's CAPI CRDs serve v1beta2
    CAPG_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bdec420448b81cc57f5b53bbcf491c0ed53b6e3ca97da722f69f386a373afe50"

    "${E2E_TEST_BIN}" -test.v \
      -test.run="${CI_TESTS_RUN:-TestCreateCluster}" \
      -test.parallel=20 \
      --e2e.platform=GCP \
      --e2e.base-domain="${BASE_DOMAIN}" \
      --e2e.external-dns-domain="${BASE_DOMAIN}" \
      --e2e.annotations="hypershift.openshift.io/control-plane-operator-image=${CPO_IMAGE}" \
      --e2e.annotations="hypershift.openshift.io/capi-provider-gcp-image=${CAPG_IMAGE}" \
      --e2e.annotations="hypershift.openshift.io/pod-security-admission-label-override=baseline" \
      --e2e.disable-cluster-capabilities=ImageRegistry \
      --e2e.disable-cluster-capabilities=Console \
      --e2e.disable-cluster-capabilities=Ingress \
      --e2e.gcp-project="${HC_PROJECT_ID}" \
      --e2e.gcp-region="${GCP_REGION}" \
      --e2e.gcp-network="${VPC_NAME}" \
      --e2e.gcp-psc-subnet="${PSC_SUBNET}" \
      --e2e.gcp-endpoint-access=PublicAndPrivate \
      --e2e.gcp-wif-project-number="${WIF_PROJECT_NUMBER}" \
      --e2e.gcp-wif-pool-id="${WIF_POOL_ID}" \
      --e2e.gcp-wif-provider-id="${WIF_PROVIDER_ID}" \
      --e2e.gcp-nodepool-sa="${NODEPOOL_SA}" \
      --e2e.gcp-controlplane-sa="${CONTROLPLANE_SA}" \
      --e2e.gcp-cloudcontroller-sa="${CLOUDCONTROLLER_SA}" \
      --e2e.gcp-storage-sa="${STORAGE_SA}" \
      --e2e.gcp-sa-signing-key-path="${SA_SIGNING_KEY_PATH}" \
      --e2e.gcp-oidc-issuer-url="${OIDC_ISSUER_URL}" \
      --e2e.gcp-boot-image="${HYPERSHIFT_GCP_BOOT_IMAGE}" \
      --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
      --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
      --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}"
else
    # TODO(GCP-295): Remove CPO image override after multizone fix is merged
    CPO_IMAGE="quay.io/cveiga/hypershift:GCP-295-e2e-gcp-platform-support-4f9d5c16"
    # TODO(GCP-426): Remove CAPG image override once HyperShift's CAPI CRDs serve v1beta2
    CAPG_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bdec420448b81cc57f5b53bbcf491c0ed53b6e3ca97da722f69f386a373afe50"

    echo "Running e2e tests using hack/ci-test-e2e.sh"
    hack/ci-test-e2e.sh -test.v \
      -test.run="${CI_TESTS_RUN:-TestCreateCluster}" \
      -test.parallel=20 \
      --e2e.platform=GCP \
      --e2e.base-domain="${BASE_DOMAIN}" \
      --e2e.external-dns-domain="${BASE_DOMAIN}" \
      --e2e.annotations="hypershift.openshift.io/control-plane-operator-image=${CPO_IMAGE}" \
      --e2e.annotations="hypershift.openshift.io/capi-provider-gcp-image=${CAPG_IMAGE}" \
      --e2e.annotations="hypershift.openshift.io/pod-security-admission-label-override=baseline" \
      --e2e.disable-cluster-capabilities=ImageRegistry \
      --e2e.disable-cluster-capabilities=Console \
      --e2e.disable-cluster-capabilities=Ingress \
      --e2e.gcp-project="${HC_PROJECT_ID}" \
      --e2e.gcp-region="${GCP_REGION}" \
      --e2e.gcp-network="${VPC_NAME}" \
      --e2e.gcp-psc-subnet="${PSC_SUBNET}" \
      --e2e.gcp-endpoint-access=PublicAndPrivate \
      --e2e.gcp-wif-project-number="${WIF_PROJECT_NUMBER}" \
      --e2e.gcp-wif-pool-id="${WIF_POOL_ID}" \
      --e2e.gcp-wif-provider-id="${WIF_PROVIDER_ID}" \
      --e2e.gcp-nodepool-sa="${NODEPOOL_SA}" \
      --e2e.gcp-controlplane-sa="${CONTROLPLANE_SA}" \
      --e2e.gcp-cloudcontroller-sa="${CLOUDCONTROLLER_SA}" \
      --e2e.gcp-storage-sa="${STORAGE_SA}" \
      --e2e.gcp-sa-signing-key-path="${SA_SIGNING_KEY_PATH}" \
      --e2e.gcp-oidc-issuer-url="${OIDC_ISSUER_URL}" \
      --e2e.gcp-boot-image="${HYPERSHIFT_GCP_BOOT_IMAGE}" \
      --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
      --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
      --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}"
fi
