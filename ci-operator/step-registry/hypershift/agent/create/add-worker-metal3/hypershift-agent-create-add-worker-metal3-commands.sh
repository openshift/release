#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker metal3 command ************"

source "${SHARED_DIR}/packet-conf.sh"
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

sleep 3600