#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "modify for rehearse"
echo "************ assisted common setup infra command ************"

timeout -s 9 175m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail
source /root/config.sh

set -x
cd /home/assisted
make \${MAKEFILE_SETUP_TARGET:-setup run}
EOF
