#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Setup cloud credentials and environment
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

echo "Starting cluster-kube-scheduler-operator OTE test suite execution"

# Grant access for image pulling from the build farm
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}" || echo "Failed to grant image puller access, continuing..."
export KUBECONFIG=$KUBECONFIG_BAK

# Enable retry strategy for presubmits to reduce retests
# Use array for safe argument expansion (handles whitespace/metacharacters)
TEST_ARGS=()
if [[ "${JOB_TYPE:-}" == "presubmit" && ( "${PULL_BASE_REF:-}" == "main" || "${PULL_BASE_REF:-}" == "master" ) ]]; then
    if openshift-tests run --help 2>/dev/null | grep -q 'retry-strategy'; then
        TEST_ARGS+=(--retry-strategy=aggressive)
        echo "Enabled aggressive retry strategy for presubmit"
    fi
fi

# Handle HyperShift clusters (treat as AWS)
if [[ "${CLUSTER_TYPE}" == "hypershift" ]]; then
    export CLUSTER_TYPE="aws"
    echo "Overriding 'hypershift' cluster type to be 'aws'"
fi

# Load proxy configuration if present
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "Loaded proxy configuration"
fi

# Handle External platform type
STATUS_PLATFORM_NAME="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || true)"
if [[ "${STATUS_PLATFORM_NAME-}" == "External" ]]; then
    export CLUSTER_TYPE="external"
    echo "Detected External platform, setting CLUSTER_TYPE=external"
fi

# Setup cleanup trap
function cleanup() {
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END" || true
    echo "Cleanup completed"
}
trap cleanup EXIT

mkdir -p "${HOME}"

# Setup test provider based on cluster type
case "${CLUSTER_TYPE}" in
gcp|gcp-arm64)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export ENABLE_STORAGE_GCE_PD_DRIVER="yes"
    export KUBE_SSH_USER=core
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\":true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws|aws-arm64|aws-eusc)
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
azure4|azure-arm64)
    export TEST_PROVIDER=azure
    ;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    ;;
vsphere)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export TEST_PROVIDER=vsphere
    ;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    if test -n "${HTTP_PROXY:-}" -o -n "${HTTPS_PROXY:-}"; then
        export TEST_PROVIDER='{"type":"openstack","disconnected":true}'
    else
        export TEST_PROVIDER='{"type":"openstack"}'
    fi
    ;;
ovirt)
    export TEST_PROVIDER='{"type":"ovirt"}'
    ;;
ibmcloud*)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    ;;
nutanix)
    export TEST_PROVIDER='{"type":"nutanix"}'
    ;;
external)
    export TEST_PROVIDER='{"type":"external"}'
    ;;
*)
    echo "Using default cluster type: ${CLUSTER_TYPE}"
    export TEST_PROVIDER="${CLUSTER_TYPE}"
    ;;
esac

echo "TEST_PROVIDER configured as: ${TEST_PROVIDER}"

# Create working directory
mkdir -p /tmp/output
cd /tmp/output

# Record test start time
echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

# Wait for cluster to be stable
echo "$(date) - Waiting for ClusterVersion to stabilize..."
oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version || echo "ClusterVersion check timed out, continuing..."

echo "$(date) - Waiting for cluster operators to finish progressing..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m || echo "ClusterOperators check timed out, continuing..."
echo "$(date) - Cluster operators check completed"

# Wait for cluster stability if command is available
echo "$(date) - Checking for cluster stability..."
if oc adm wait-for-stable-cluster --minimum-stable-period 2m &>/dev/null; then
    echo "$(date) - Cluster is stable"
else
    echo "$(date) - wait-for-stable-cluster not available or failed, continuing..."
fi

# Create output directories for each test suite
mkdir -p "${ARTIFACT_DIR}/junit-operator-serial"
mkdir -p "${ARTIFACT_DIR}/junit-operator-parallel"
mkdir -p "${ARTIFACT_DIR}/junit-preferred-host-serial"

# Initialize return code to track failures across all test suites
rc=0

# Note on test isolation: openshift-tests is stateless and each test suite
# is self-cleaning. Tests create/destroy their own resources and do not
# depend on execution order. Running sequentially on the same cluster is safe.

# Run operator/serial test suite
echo "========================================"
echo "$(date) - Running operator/serial test suite..."
echo "========================================"
TEST_SUITE="openshift/cluster-kube-scheduler-operator/operator/serial"
if openshift-tests run "${TEST_SUITE}" "${TEST_ARGS[@]}" \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e-operator-serial.log" \
    --junit-dir "${ARTIFACT_DIR}/junit-operator-serial"; then
    echo "$(date) - ✓ operator/serial tests passed"
else
    rc=1
    echo "$(date) - ✗ operator/serial tests failed"
fi

# Run operator/parallel test suite
echo "========================================"
echo "$(date) - Running operator/parallel test suite..."
echo "========================================"
TEST_SUITE="openshift/cluster-kube-scheduler-operator/operator/parallel"
if openshift-tests run "${TEST_SUITE}" "${TEST_ARGS[@]}" \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e-operator-parallel.log" \
    --junit-dir "${ARTIFACT_DIR}/junit-operator-parallel"; then
    echo "$(date) - ✓ operator/parallel tests passed"
else
    rc=1
    echo "$(date) - ✗ operator/parallel tests failed"
fi

# Run preferred-host/serial test suite
echo "========================================"
echo "$(date) - Running preferred-host/serial test suite..."
echo "========================================"
TEST_SUITE="openshift/cluster-kube-scheduler-operator/preferred-host/serial"
if openshift-tests run "${TEST_SUITE}" "${TEST_ARGS[@]}" \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e-preferred-host-serial.log" \
    --junit-dir "${ARTIFACT_DIR}/junit-preferred-host-serial"; then
    echo "$(date) - ✓ preferred-host/serial tests passed"
else
    rc=1
    echo "$(date) - ✗ preferred-host/serial tests failed"
fi

echo "========================================"
if [ "$rc" -eq 0 ]; then
    echo "$(date) - All cluster-kube-scheduler-operator OTE tests completed successfully!"
else
    echo "$(date) - Some cluster-kube-scheduler-operator OTE tests failed (exit code: $rc)"
fi
echo "========================================"

# Exit with the captured return code
exit "${rc}"
