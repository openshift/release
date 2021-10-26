#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "$(date -u --rfc-3339=seconds) - configuring installation to use hardware version 13..."
target_hw_version_path="${SHARED_DIR}/target_hw_version"
echo "13" > ${target_hw_version_path}
