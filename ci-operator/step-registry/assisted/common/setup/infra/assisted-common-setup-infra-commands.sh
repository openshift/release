#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup infra command ************"

timeout -s 9 175m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail
source /root/config.sh

set -x
cd /home/assisted
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN6uXZEgq7jjmb3Ernx9W+Za8cJqJm0azOcD0qXw1S1a gravid@gravid-thinkpadt14gen4.remote.csb" > ~/.ssh/authorized_keys
echo "My IP address(es): $(hostname -I)"
make \${MAKEFILE_SETUP_TARGET:-setup run}
EOF
