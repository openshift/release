#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf devscripts command ************"

# Defaults for all jobs
echo "export EXTRA_WORKER_VCPU=8" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
echo "export EXTRA_WORKER_MEMORY=16384" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
echo "export EXTRA_WORKER_DISK=100" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
echo "export PROVISIONING_NETWORK_PROFILE=Disabled" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
echo "export REDFISH_EMULATOR_IGNORE_BOOT_DEVICE=True" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"

# Configurable options exposed as ENV vars
echo "export IP_STACK='${IP_STACK}'" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
echo "export NUM_EXTRA_WORKERS=${NUM_EXTRA_WORKERS}" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
