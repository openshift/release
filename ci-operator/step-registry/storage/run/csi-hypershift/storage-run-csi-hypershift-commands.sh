#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME=/tmp/home
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
mkdir -p "${HOME}"

# Set up CSI driver manifest files
if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES="${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
fi
if [[ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]] && [[ -e "${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_OCP_CSI_DRIVER_FILES="${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}"
fi

# Auto-detect TEST_PROVIDER from the guest cluster's Infrastructure if not explicitly set.
# This avoids relying on CLUSTER_TYPE which reflects the management cluster's platform.
if [[ -z "${TEST_PROVIDER:-}" ]]; then
    PLATFORM="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}')"
    echo "Detected infrastructure platform: ${PLATFORM}"
    case "${PLATFORM}" in
    Azure)
        export TEST_PROVIDER='{"type":"azure"}'
        ;;
    AWS)
        REGION="$(oc get Infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')"
        ZONE="$(oc get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)"
        export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
        ;;
    GCP)
        PROJECT="$(oc get Infrastructure cluster -o jsonpath='{.status.platformStatus.gcp.projectID}')"
        REGION="$(oc get Infrastructure cluster -o jsonpath='{.status.platformStatus.gcp.region}')"
        export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\":true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
        ;;
    External|None|"")
        export TEST_PROVIDER='{"type":"none"}'
        ;;
    *)
        echo "WARNING: Unknown infrastructure platform '${PLATFORM}', defaulting TEST_PROVIDER to none"
        export TEST_PROVIDER='{"type":"none"}'
        ;;
    esac
    echo "Using TEST_PROVIDER: ${TEST_PROVIDER}"
fi

# Set HyperShift management cluster env vars required by openshift-tests monitors.
# The management cluster kubeconfig is saved by cucushift-hypershift-extended-enable-guest,
# and the cluster name is saved by hypershift-azure-create.
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi
if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
    CLUSTER_NAME="$(cat "${SHARED_DIR}/cluster-name")"
    export HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE="clusters-${CLUSTER_NAME}"
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

if [[ -n "${TEST_SKIPS}" ]]; then
    TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
    echo "${TESTS}" | grep -v "${TEST_SKIPS}" > /tmp/tests
    echo "Skipping tests:"
    echo "${TESTS}" | grep "${TEST_SKIPS}" || {
        echo "Error: no tests were found matching the TEST_SKIPS regex: ${TEST_SKIPS}"
        exit 1
    }
    TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit" 2>&1 | tee /tmp/openshift-csi-tests.log
exit_code=${PIPESTATUS[0]}

# MonitorTest failures are expected on HyperShift guest clusters because some monitors
# (e.g. machine watcher, cloud service availability) are not applicable to hosted clusters.
# This follows the same pattern used by hypershift/kubevirt and other HyperShift CI jobs.
if [[ -n "${SKIP_MONITOR_TEST:-}" ]] && \
   grep -q "failed due to a MonitorTest failure" /tmp/openshift-csi-tests.log; then
    echo "Ignoring MonitorTest failure on HyperShift guest cluster"
    exit_code=0
fi

exit ${exit_code}
