#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator conf command ************"

cat << EOF > "${SHARED_DIR}/dev-scripts-additional-config"
export IP_STACK="${IP_STACK}"
export NUM_EXTRA_WORKERS=1
export EXTRA_WORKER_VCPU=8
export EXTRA_WORKER_MEMORY=32768
export EXTRA_WORKER_DISK=120
export PROVISIONING_NETWORK_PROFILE=Disabled
export REDFISH_EMULATOR_IGNORE_BOOT_DEVICE=True
EOF
