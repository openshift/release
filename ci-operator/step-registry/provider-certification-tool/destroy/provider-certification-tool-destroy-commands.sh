#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Run destroy command
./openshift-provider-cert-linux-amd64 destroy
