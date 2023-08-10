#!/usr/bin/env bash

set -Eeuo pipefail

E2E_TEST_CASES=${E2E_TEST_CASES:-"e2e-presubmit"}

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

# OpenStack CI jobs have a defined alternative flavor when testing a vertical scale.
if test -f "${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"
then
	OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE="$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE")"
	export OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE
fi

make ${E2E_TEST_CASES}
