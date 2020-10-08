#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

(
# When debugging, we don't care about pipe failures and other errors
set +o nounset; set +o errexit; set +o pipefail; set -o xtrace
echo "SHARED_DIR=${SHARED_DIR}"
echo "ARTIFACT_DIR=${ARTIFACT_DIR}"
mount | grep "$(basename ${SHARED_DIR})"
[ -n "${SHARED_DIR}" ] && ls -l "${SHARED_DIR}/"
[ -n "${ARTIFACT_DIR}" ] && ls -l "${ARTIFACT_DIR}/"
) || true

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mkdir -p "${HOME}"

# Override the upstream docker.io registry due to issues with rate limiting
# https://bugzilla.redhat.com/show_bug.cgi?id=1895107
# sjenning: TODO: use of personal repo is temporary; should find long term location for these mirrored images
export KUBE_TEST_REPO_LIST=${HOME}/repo_list.yaml
cat << EOREGISTRY > ${KUBE_TEST_REPO_LIST}
dockerGluster: quay.io/sjenning
dockerLibraryRegistry: quay.io/sjenning
e2eRegistry: quay.io/multiarch-k8s-e2e
e2eVolumeRegistry: quay.io/multiarch-k8s-e2e
quayIncubator: quay.io/multiarch-k8s-e2e
quayK8sCSI: quay.io/multiarch-k8s-e2e
k8sCSI: quay.io/multiarch-k8s-e2e
promoterE2eRegistry: quay.io/multiarch-k8s-e2e
sigStorageRegistry: quay.io/multiarch-k8s-e2e
EOREGISTRY

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

export TEST_PROVIDER='{"type":"openstack"}'

mkdir -p /tmp/output
cd /tmp/output

function upgrade() {
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

function suite() {
    if [[ -n "${TEST_SKIPS}" ]]; then
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
        echo "Skipping tests:"
        echo "${TESTS}" | grep "${TEST_SKIPS}"
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
    fi

    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
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
