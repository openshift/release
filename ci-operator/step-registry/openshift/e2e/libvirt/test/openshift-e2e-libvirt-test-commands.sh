#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
# Initial check
if [[ "${CLUSTER_TYPE}" != "libvirt-ppc64le" ]] && [[ "${CLUSTER_TYPE}" != "libvirt-s390x" ]] ; then
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

function upgrade() {
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
    set +x
}

function suite() {
    if [ -f "${SHARED_DIR}/excluded_tests" ]; then
        cat > ${SHARED_DIR}/invert_excluded.py <<EOSCRIPT
#!/usr/libexec/platform-python
import sys
all_tests = set()
excluded_tests = set()
for l in sys.stdin.readlines():
    all_tests.add(l.strip())
with open(sys.argv[1], "r") as f:
    for l in f.readlines():
        excluded_tests.add(l.strip())
test_suite = all_tests - excluded_tests
for t in test_suite:
    print(t)
EOSCRIPT
      chmod +x ${SHARED_DIR}/invert_excluded.py
      openshift-tests run "${TEST_SUITE}" --dry-run | ${SHARED_DIR}/invert_excluded.py ${SHARED_DIR}/excluded_tests > ${SHARED_DIR}/tests
      TEST_ARGS="${TEST_ARGS:-} --file ${SHARED_DIR}/tests"
    fi

    if [ "$BRANCH" = "4.6" ]; then
# use s390x or ppc64le builds of e2e test images
# this is a multi-arch image
        cat << EOREGISTRY > ${SHARED_DIR}/kube-test-repo-list
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
export KUBE_TEST_REPO_LIST=${SHARED_DIR}/kube-test-repo-list
    else
        TEST_ARGS="${TEST_ARGS:-} --from-repository=quay.io/multi-arch/community-e2e-images"
    fi

    VERBOSITY="" # "--v 9"
    set -x
    openshift-tests run \
        ${VERBOSITY} \
        "${TEST_SUITE}" \
        ${TEST_ARGS:-} \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
    set +x
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

case "${TEST_TYPE}" in
conformance-parallel)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
conformance-serial)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/serial suite
    ;;
jenkins-e2e-rhel-only)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/jenkins-e2e-rhel-only suite
    ;;
image-ecosystem)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/image-ecosystem suite
    ;;
upgrade)
    upgrade
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
