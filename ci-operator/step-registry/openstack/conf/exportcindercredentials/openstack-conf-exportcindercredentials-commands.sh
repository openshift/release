#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

yq -r '.clouds."'"${OS_CLOUD}"'" | paths(scalars) as $p | "export OS_" + ($p|last|ascii_upcase) + "=\"" + (getpath($p)|tostring) + "\""' \
	< "${CLUSTER_PROFILE_DIR}/clouds.yaml" \
	> "${SHARED_DIR}/cinder_credentials.sh"
