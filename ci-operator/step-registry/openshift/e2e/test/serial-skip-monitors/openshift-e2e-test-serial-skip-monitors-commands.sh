#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

# Optional shared test-tool environment. Projects that install developer tools
# in a preceding step can expose them to openshift-tests and its extensions by
# writing this file into SHARED_DIR.
if [[ -f "${SHARED_DIR}/cluster-debug-tools.env" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cluster-debug-tools.env"
fi

echo "Debug artifact generation" > ${ARTIFACT_DIR}/dummy.log

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm. In
# order to do that, we need to unset the KUBECONFIG so we talk to the
# build farm, not the cluster under test.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    if [[ "${WAS_TRACING}" == true ]]; then
        set -x
    fi
fi

STATUS_PLATFORM_NAME="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}' || true)"
if [[ "${STATUS_PLATFORM_NAME-}" == "External" ]]; then
    export CLUSTER_TYPE="external"
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

mkdir -p "${HOME}"

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

TEST_PROVIDER="${TEST_PROVIDER:-}"
if [[ -n "${TEST_PROVIDER}" ]]; then
    export TEST_PROVIDER
fi

set -x
# Run serial test suite with SKIP_MONITOR_TEST to ignore monitor-only failures
SKIP_MONITOR_TEST="${SKIP_MONITOR_TEST}" openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit" &
wait "$!"
set +x
