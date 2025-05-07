#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
  printf '%s: INFO: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
# if test -f "${SHARED_DIR}/proxy-conf.sh"
# then
#	# shellcheck disable=SC1090
#	source "${SHARED_DIR}/proxy-conf.sh"
# fi

info "THE LEASED_RESOURCE IS: ${LEASED_RESOURCE}"

[[ "$LEASED_RESOURCE" == openstack* ]] && CLUSTER_TYPE="${LEASED_RESOURCE}"

info "THE CLUSTER TYPE IS: ${CLUSTER_TYPE}"
