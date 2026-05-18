#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

mkdir -p "${HOME}"

echo "Debug artifact generation" > ${ARTIFACT_DIR}/dummy.log

KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

if [[ "${CLUSTER_TYPE}" == "hypershift" ]]; then
    export CLUSTER_TYPE="aws"
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

STATUS_PLATFORM_NAME="$(oc get Infrastructure cluster -o jsonpath='{.status.platform}' || true)"
if [[ "${STATUS_PLATFORM_NAME-}" == "External" ]]; then
    export CLUSTER_TYPE="external"
fi

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi
if [[ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]] && [[ -e "${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_OCP_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

# set up cloud-provider-specific env vars
case "${CLUSTER_TYPE}" in
gcp|gcp-arm64)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export ENABLE_STORAGE_GCE_PD_DRIVER="yes"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws|aws-arm64|aws-eusc)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
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
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE"
    sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
    sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    export TEST_PROVIDER=vsphere;;
nutanix) export TEST_PROVIDER='{"type":"nutanix"}' ;;
external) export TEST_PROVIDER='{"type":"external"}' ;;
*) export TEST_PROVIDER="${CLUSTER_TYPE}";;
esac

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.8-kube-1.22-api-removals-in-4.9":"true"}}' --type=merge || true

oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version || true

# Parse shard parameters from SHARD_ARGS (auto-set by ci-operator)
SHARD_ID=""
SHARD_COUNT=""
if [[ -n "${SHARD_ARGS:-}" ]]; then
    SHARD_ID=$(echo "${SHARD_ARGS}" | grep -oP '(?<=--shard-id )\d+' || true)
    SHARD_COUNT=$(echo "${SHARD_ARGS}" | grep -oP '(?<=--shard-count )\d+' || true)
fi

if [[ -z "${SHARD_ID}" || -z "${SHARD_COUNT}" ]]; then
    echo "No shard parameters found, falling back to standard behavior"
    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    exit $?
fi

echo "Balanced sharding: shard ${SHARD_ID} of ${SHARD_COUNT}"

ALL_TESTS=$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")

if [[ -z "${ALL_TESTS}" ]]; then
    echo "ERROR: No tests found in suite ${TEST_SUITE}"
    exit 1
fi

if [[ -n "${TEST_SKIPS:-}" ]]; then
    echo "Skipping tests matching: ${TEST_SKIPS}"
    SKIPPED=$(echo "${ALL_TESTS}" | grep "${TEST_SKIPS}" || true)
    if [[ -n "${SKIPPED}" ]]; then
        echo "Skipped tests:"
        echo "${SKIPPED}"
    fi
    ALL_TESTS=$(echo "${ALL_TESTS}" | grep -v "${TEST_SKIPS}") || {
        echo "Error: all tests were filtered out by TEST_SKIPS regex"
        exit 1
    }
fi

TOTAL_TESTS=$(echo "${ALL_TESTS}" | wc -l | tr -d ' ')
echo "Total tests in suite after filtering: ${TOTAL_TESTS}"

# Slow test handling: if SLOW_TESTS regex is set, reorder so that slow tests
# are placed first and interleaved across shards. This prevents multiple
# long-running tests from clustering on the same shard.
if [[ -n "${SLOW_TESTS:-}" ]]; then
    SLOW_MATCHED=$(echo "${ALL_TESTS}" | grep "${SLOW_TESTS}" || true)
    FAST_REMAINING=$(echo "${ALL_TESTS}" | grep -v "${SLOW_TESTS}" || true)
    if [[ -n "${SLOW_MATCHED}" ]]; then
        SLOW_COUNT=$(echo "${SLOW_MATCHED}" | wc -l | tr -d ' ')
        echo "Slow tests identified (${SLOW_COUNT}), placing them first for even distribution:"
        echo "${SLOW_MATCHED}"
        if [[ -n "${FAST_REMAINING}" ]]; then
            ALL_TESTS=$(printf '%s\n%s' "${SLOW_MATCHED}" "${FAST_REMAINING}")
        else
            ALL_TESTS="${SLOW_MATCHED}"
        fi
    fi
fi

echo "${ALL_TESTS}" | awk -v id="${SHARD_ID}" -v count="${SHARD_COUNT}" \
    '(NR - 1) % count == (id - 1) % count { print }' > /tmp/shard-tests

SHARD_TEST_COUNT=$(wc -l < /tmp/shard-tests | tr -d ' ')
echo "Tests assigned to this shard: ${SHARD_TEST_COUNT} of ${TOTAL_TESTS}"
echo "Assigned tests:"
cat /tmp/shard-tests

if [[ "${SHARD_TEST_COUNT}" -eq 0 ]]; then
    echo "No tests assigned to this shard. Exiting successfully."
    exit 0
fi

set -x
openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
    --file /tmp/shard-tests \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit"
