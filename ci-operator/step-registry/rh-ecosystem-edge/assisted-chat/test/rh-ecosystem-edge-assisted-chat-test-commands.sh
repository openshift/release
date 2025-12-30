#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc create namespace $NAMESPACE || true

printenv
if ! [[ "$JOB_NAME" == *"rh-ecosystem-edge-assisted-chat"* ]]; then
    git clone https://github.com/rh-ecosystem-edge/assisted-chat.git
    cd assisted-chat
fi

make ci-test
