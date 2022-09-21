#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup infra command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

timeout -s 9 175m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
source /root/config.sh
cd /home/assisted
make \${MAKEFILE_SETUP_TARGET:-setup run}
EOF
