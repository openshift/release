#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Download yq

if ! command -v yq &> /dev/null
then
  curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq && chmod +x /tmp/yq
fi

# set shutdown grace period to enable testing graceful shutdown
/tmp/yq e -i '.spec.kubeletConfig |= . + {"shutdownGracePeriod": "600s", "shutdownGracePeriodCriticalPods": "300s"}' "${SHARED_DIR}/manifest_single-node-kubeletconfig.yml"