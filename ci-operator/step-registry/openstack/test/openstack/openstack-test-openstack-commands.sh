#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

declare TEST_ARGS=''

# Force the IPv6 endpoint
if [[ "${CONFIG_TYPE}" == *"singlestackv6"* ]]; then
	export OS_CLOUD="${OS_CLOUD}-ipv6"
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

if [[ -n "${OPENSTACK_TEST_SKIPS}" ]]; then
	TESTS="$(openstack-tests run --dry-run openshift/openstack)"
	echo "${TESTS}" | grep -v "${OPENSTACK_TEST_SKIPS}" >/tmp/tests
	echo "Skipping tests:"
	echo "${TESTS}" | grep "${OPENSTACK_TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the OPENSTACK_TEST_SKIPS regex:'; echo "$OPENSTACK_TEST_SKIPS"; return $exit_code; }
	TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

openstack-tests run openshift/openstack ${TEST_ARGS:-} \
	--junit-dir "${ARTIFACT_DIR}/junit" \
	-o "${ARTIFACT_DIR}/e2e.log"
