#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

show_msg "Run must-gather for opct environment"
oc adm inspect ns/opct --dest-dir=${ARTIFACT_DIR}/must-gather
