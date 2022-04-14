#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup test command ************"

# Get packet | vsphere configuration
# shellcheck source=/dev/null
set +e
source "${SHARED_DIR}/packet-conf.sh"
source "${SHARED_DIR}/ci-machine-config.sh"
set -e

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

cat <<EOT >> ${SHARED_DIR}/ssh_config
Host ci_machine
  User root
  HostName ${IP}
  ConnectTimeout 5
  StrictHostKeyChecking no
  ServerAliveInterval 90
  LogLevel ERROR
  IdentityFile ${SSH_KEY_FILE}
EOT

timeout -s 9 175m ssh -F ${SHARED_DIR}/ssh_config ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -xeuo pipefail
source /root/config.sh
cd /home/assisted
make \${MAKEFILE_TARGET:-create_full_environment run test_parallel}
EOF
