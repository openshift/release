#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Configure env for test run
cp $KUBECONFIG /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig


# Execute tests

# Copy results and artifacts to $ARTIFACT_DIR