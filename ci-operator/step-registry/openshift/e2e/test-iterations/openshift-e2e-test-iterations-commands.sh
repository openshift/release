#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

echo "Running test suite ${TEST_ITERATIONS} times"

# Grant access for image pulling from the build farm
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

# set up cloud-provider-specific env vars
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
external) export TEST_PROVIDER='{"type":"external"}';;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

mkdir -p "${HOME}"
mkdir -p /tmp/output
cd /tmp/output

TEST_ARGS="${TEST_ARGS:-} ${SHARD_ARGS:-}"

# Run the test suite multiple times
for i in $(seq 1 ${TEST_ITERATIONS}); do
    echo "===== Test iteration $i of ${TEST_ITERATIONS} ====="
    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START_${i}"

    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e-${i}.log" \
        --junit-dir "${ARTIFACT_DIR}/junit-${i}" || {
        echo "Test iteration $i failed"
        # Continue to next iteration even if this one fails
    }
    set +x

    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END_${i}"
    echo "Completed iteration $i of ${TEST_ITERATIONS}"
done

echo "All ${TEST_ITERATIONS} test iterations completed"
