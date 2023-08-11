#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_NAMESPACE="stack"

cd "$(mktemp -d)"

go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo
git clone https://github.com/devfile/registry.git -b main
cd registry

# Install golang modules
cd tests/rhtap && \
    go mod tidy && \
    go mod vendor && \
    cd ../..


oc create namespace "${TEST_NAMESPACE}"
ginkgo run  \
  --timeout 2h \
  tests/rhtap -- -samplesFile "$(pwd)/extraDevfileEntries.yaml" -namespace="stack"
