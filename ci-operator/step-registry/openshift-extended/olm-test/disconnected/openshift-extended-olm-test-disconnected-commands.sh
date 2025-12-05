#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

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

# Starting in 4.21, we will aggressively retry test failures only in
# presubmits to determine if a failure is a flake or legitimate. This is
# to reduce the number of retests on PR's.
if [[ "$JOB_TYPE" == "presubmit" && ( "$PULL_BASE_REF" == "main" || "$PULL_BASE_REF" == "master" ) ]]; then
    if openshift-tests run --help | grep -q 'retry-strategy'; then
        TEST_ARGS+=" --retry-strategy=aggressive"
    fi
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function cleanup() {
    echo "Requesting risk analysis for test failures in this job run from sippy:"
    openshift-tests risk-analysis --junit-dir "${ARTIFACT_DIR}/junit" || true

    echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
}
trap cleanup EXIT

mkdir -p "${HOME}"

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

if [[ -f "${SHARED_DIR}/mirror-tests-image" ]]; then
    TEST_ARGS="${TEST_ARGS:-}"
    TEST_ARGS+=" --from-repository=$(<"${SHARED_DIR}/mirror-tests-image")"
fi

TEST_ARGS="${TEST_ARGS:-} ${SHARD_ARGS:-}"

# set up cloud-provider-specific env vars
case "${CLUSTER_TYPE}" in
gcp|gcp-arm64)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    # In k8s 1.24 this is required to run GCP PD tests. See: https://github.com/kubernetes/kubernetes/pull/109541
    export ENABLE_STORAGE_GCE_PD_DRIVER="yes"
    export KUBE_SSH_USER=core
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    # TODO: make openshift-tests auto-discover this from cluster config
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\",\"disconnected\":true}"
    ;;
aws|aws-arm64)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    # TODO: make openshift-tests auto-discover this from cluster config
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true,\"disconnected\":true}"
    export KUBE_SSH_USER=core
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'. This step only supports GCP and AWS clusters."; exit 1;;
esac

mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == "gcp" || "${CLUSTER_TYPE}" == "gcp-arm64"  ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

# Preserve the && chaining in this function, because it is called from and AND-OR list so it doesn't get errexit.
function upgrade() {
    set -x &&
    TARGET_RELEASES="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" &&
    if [[ -f "${SHARED_DIR}/override-upgrade" ]]; then
        TARGET_RELEASES="$(< "${SHARED_DIR}/override-upgrade")" &&
        echo "Overriding upgrade target to ${TARGET_RELEASES}"
    fi &&
    openshift-tests run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${TARGET_RELEASES}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!" &&
    set +x
}

# upgrade_conformance runs the upgrade and the parallel tests, and exits with an error if either fails.
function upgrade_conformance() {
    local exit_code=0 &&
    upgrade || exit_code=$? &&
    PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)" &&
    HISTORY_LENGTH="$(oc get -o jsonpath='{range .status.history[*]}{.version}{"\n"}{end}' clusterversion version | wc -l)" &&
    if test 2 -gt "${HISTORY_LENGTH}"
    then
        echo "Skipping conformance suite because ClusterVersion only has ${HISTORY_LENGTH} entries, so an update was not run"
    elif test False != "${PROGRESSING}"
    then
        echo "Skipping conformance suite because post-update ClusterVersion Progressing=${PROGRESSING}"
    else
        TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite || exit_code=$?
    fi &&
    return $exit_code
}

# Preserve the && chaining in this function, because it is called from and AND-OR list so it doesn't get errexit.
function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")" &&
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
        echo "Skipping tests:" &&
        echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi &&

    set -x &&
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!" &&
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"

oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.8-kube-1.22-api-removals-in-4.9":"true"}}' --type=merge || echo 'failed to ack the 4.9 Kube v1beta1 removals; possibly API-server issue, or a pre-4.8 release image'

oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version

# wait up to 10m for the number of nodes to match the number of machines
i=0
node_check_interval=30
node_check_limit=20
while true
do
    MACHINECOUNT="$(kubectl get machines -A --no-headers | wc -l)"
    NODECOUNT="$(kubectl get nodes --no-headers | wc -l)"
    if [ "${MACHINECOUNT}" -le "${NODECOUNT}" ]
    then
      cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
      <testsuite name="cluster nodes" tests="1" failures="0">
        <testcase name="node count should match or exceed machine count"/>
      </testsuite>
EOF
        echo "$(date) - node count ($NODECOUNT) now matches or exceeds machine count ($MACHINECOUNT)"
        break
    fi
    echo "$(date) [$i/$node_check_limit] - $MACHINECOUNT Machines - $NODECOUNT Nodes"
    sleep $node_check_interval
    i=$((i+1))
    if [ $i -gt $node_check_limit ]; then
      MACHINELIST="$(kubectl get machines -A)"
      NODELIST="$(kubectl get nodes)"
      cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
      <testsuite name="cluster nodes" tests="1" failures="1">
        <testcase name="node count should match or exceed machine count">
          <failure message="">
            Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT).
            $MACHINELIST
            $NODELIST
          </failure>
        </testcase>
      </testsuite>
EOF

        echo "Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT)."
        exit 1
    fi
done

# wait for all nodes to reach Ready=true to ensure that all machines and nodes came up, before we run
# any e2e tests that might require specific workload capacity.
echo "$(date) - waiting for nodes to be ready..."
ret=0
oc wait nodes --all --for=condition=Ready=true --timeout=10m || ret=$?
if [[ "$ret" == 0 ]]; then
      cat >"${ARTIFACT_DIR}/junit_node_ready.xml" <<EOF
      <testsuite name="cluster nodes ready" tests="1" failures="0">
        <testcase name="all nodes should be ready"/>
      </testsuite>
EOF
    echo "$(date) - all nodes are ready"
else
    set +e
    getNodeResult=$(oc get nodes)
    set -e
    cat >"${ARTIFACT_DIR}/junit_node_ready.xml" <<EOF
    <testsuite name="cluster nodes ready" tests="1" failures="1">
      <testcase name="all nodes should be ready">
        <failure message="">
          Timed out waiting for nodes to be ready. Return code: $ret.
          oc get nodes
          $getNodeResult
        </failure>
      </testcase>
    </testsuite>
EOF
    echo "Timed out waiting for nodes to be ready. Return code: $ret."
    exit 1
fi

# wait for all clusteroperators to finish progressing
echo "$(date) - waiting for clusteroperators to finish progressing..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=10m
echo "$(date) - all clusteroperators are done progressing."


oc get featuregate -o yaml || true
oc get CatalogSource -A -o yaml || true
oc get ImageDigestMirrorSet -o yaml || true
oc get ImageTagMirrorSet -o yaml || true
oc get ImageContentSourcePolicy -o yaml || true

# wait longer if the new command is available
echo "$(date) - waiting for oc adm wait-for-stable-cluster..."
if oc adm wait-for-stable-cluster --minimum-stable-period 2m &>/dev/null; then
	echo "$(date) - oc adm reports cluster is stable."
else
	echo "$(date) - oc adm wait-for-stable-cluster is not available in this release"
fi

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade_conformance
    ;;
upgrade)
    upgrade
    ;;
suite-conformance)
    suite
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
