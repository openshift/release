#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

# HACK: HyperShift clusters use their own profile type, but the cluster type
# underneath is actually AWS and the type identifier is derived from the profile
# type.
if [[ "${CLUSTER_TYPE}" == "hypershift" ]]; then
    export CLUSTER_TYPE="aws"
    echo "Overriding 'hypershift' cluster type to be 'aws'"
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server.
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# OpenShift clusters installed with platform type External is handled as 'None'
STATUS_PLATFORM_NAME="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}' || true)"
if [[ "${STATUS_PLATFORM_NAME-}" == "External" ]]; then
    export CLUSTER_TYPE="external"
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mkdir -p "${HOME}"

# Set up cloud-provider-specific env vars
case "${CLUSTER_TYPE}" in
gcp|gcp-arm64)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export ENABLE_STORAGE_GCE_PD_DRIVER="yes"
    export KUBE_SSH_USER=core
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws|aws-arm64|aws-eusc)
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
azure4|azure-arm64) export TEST_PROVIDER=azure;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
    ;;
vsphere)
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE"
    sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
    sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    export TEST_PROVIDER=vsphere;;
external) export TEST_PROVIDER='{"type":"external"}' ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p /tmp/output
cd /tmp/output

# Build test args as array
TEST_ARGS=()
if [[ -n "${TEST_FOCUS}" ]]; then
    TEST_ARGS+=("--run" "${TEST_FOCUS}")
fi

if [[ -n "${TEST_SKIPS}" ]]; then
    TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
    echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
    echo "Skipping tests:"
    echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; exit $exit_code; }
    TEST_ARGS+=("--file" "/tmp/tests")
fi

# Run the test multiple times
ITERATIONS=${TEST_ITERATIONS:-1}
echo "Running test ${ITERATIONS} times..."
echo "Test focus: ${TEST_FOCUS}"
echo "Test suite: ${TEST_SUITE}"

TOTAL_FAILURES=0
for i in $(seq 1 "${ITERATIONS}"); do
    echo "========================================="
    echo "Iteration $i of ${ITERATIONS}"
    echo "========================================="

    ITERATION_DIR="${ARTIFACT_DIR}/iteration-${i}"
    mkdir -p "${ITERATION_DIR}"

    set +e
    set -x
    openshift-tests run "${TEST_SUITE}" "${TEST_ARGS[@]}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ITERATION_DIR}/e2e.log" \
        --junit-dir "${ITERATION_DIR}/junit"
    EXIT_CODE=$?
    set +x
    set -e

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo "Iteration $i FAILED with exit code ${EXIT_CODE}"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    else
        echo "Iteration $i PASSED"
    fi
done

echo "========================================="
echo "Test Summary:"
echo "Total iterations: ${ITERATIONS}"
echo "Total failures: ${TOTAL_FAILURES}"
echo "Total passes: $((ITERATIONS - TOTAL_FAILURES))"
echo "========================================="

# Consolidate JUnit results
echo "Consolidating JUnit results..."
mkdir -p "${ARTIFACT_DIR}/junit"
for i in $(seq 1 "${ITERATIONS}"); do
    if [[ -d "${ARTIFACT_DIR}/iteration-${i}/junit" ]]; then
        for junit_file in "${ARTIFACT_DIR}/iteration-${i}/junit"/*.xml; do
            if [[ -f "${junit_file}" ]]; then
                cp "${junit_file}" "${ARTIFACT_DIR}/junit/iteration-${i}-$(basename "${junit_file}")"
            fi
        done
    fi
done

# Exit with failure if any iteration failed
if [[ ${TOTAL_FAILURES} -gt 0 ]]; then
    echo "Test failed in ${TOTAL_FAILURES} out of ${ITERATIONS} iterations"
    exit 1
fi

echo "All ${ITERATIONS} iterations passed!"
exit 0
