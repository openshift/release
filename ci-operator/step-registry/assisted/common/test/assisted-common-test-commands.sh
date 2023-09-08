#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common test command ************"

sleep 28800

timeout -s 9 175m ssh -F ${SHARED_DIR}/ssh_config ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail
source /root/config.sh

set -x
cd /home/assisted
make \${MAKEFILE_TARGET:-test_parallel}
EOF
