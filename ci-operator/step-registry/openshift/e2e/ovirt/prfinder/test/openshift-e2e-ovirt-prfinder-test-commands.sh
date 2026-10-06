#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o allexport

#if we dont run on master bail out
if [[ ! -n $(echo "$JOB_NAME" | grep -P '\-master\-') ]]; then
echo "this job will run only at master"
exit 0
fi

# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/ovirt.conf"
/bin/prFinder
