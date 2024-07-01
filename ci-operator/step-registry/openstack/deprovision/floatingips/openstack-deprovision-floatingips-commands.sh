#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [[ -f "${SHARED_DIR}/DELETE_FIPS" ]]; then
	xargs --verbose --no-run-if-empty \
		openstack floating ip delete \
		< "${SHARED_DIR}/DELETE_FIPS" \
		|| true
fi
