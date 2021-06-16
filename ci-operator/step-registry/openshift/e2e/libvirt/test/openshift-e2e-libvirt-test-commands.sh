#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [[ "${CLUSTER_TYPE}" != "libvirt-ppc64le" ]] && [[ "${CLUSTER_TYPE}" != "libvirt-s390x" ]] ; then
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

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
    if [[ -f "${SHARED_DIR}/excluded_tests" ]]; then

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


openshift-tests run openshift/conformance/parallel --dry-run | ${SHARED_DIR}/invert_excluded.py ${SHARED_DIR}/excluded_tests > ${SHARED_DIR}/tests

        TEST_ARGS="${TEST_ARGS:-} --file ${SHARED_DIR}/tests"
    fi

    VERBOSITY="" # "--v 9"
    openshift-tests run --from-repository quay.io/multi-arch/community-e2e-images \
	${VERBOSITY} \
	"${TEST_SUITE}" \
	${TEST_ARGS:-} \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
}
echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
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
wait "$!"
rv=$?
echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"
echo "### Fetching results"
tar -czf - ${ARTIFACT_DIR}/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
set -e
echo "### Done! (${rv})"
exit $rv
