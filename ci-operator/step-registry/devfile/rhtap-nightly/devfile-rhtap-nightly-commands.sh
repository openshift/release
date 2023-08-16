#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_NAMESPACE="stack"

cd "$(mktemp -d)"

go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo
git clone https://github.com/flacatus/registry.git -b ns_gen
cd registry

# Install golang modules
cd tests/rhtap && \
    go mod tidy && \
    go mod vendor && \
    cd ../..

oc create namespace "${TEST_NAMESPACE}"
ginkgo run -p \
  --timeout 2h \
  tests/rhtap -- -samplesFile "$(pwd)/extraDevfileEntries.yaml"
