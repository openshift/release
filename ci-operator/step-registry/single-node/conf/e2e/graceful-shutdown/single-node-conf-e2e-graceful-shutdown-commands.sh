#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# set shutdown grace period to enable testing graceful shutdown
yq e -i '.spec.kubeletConfig |= . + {"shutdownGracePeriod": "600s", "shutdownGracePeriodCriticalPods": "300s"}' "${SHARED_DIR}/manifest_single-node-kubeletconfig.yml"
