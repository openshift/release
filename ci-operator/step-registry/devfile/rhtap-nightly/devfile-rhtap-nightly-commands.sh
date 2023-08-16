#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"

go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo
git clone https://github.com/flacatus/registry.git -b fix_ns
cd registry

# Install golang modules
cd tests/rhtap && \
    go mod tidy && \
    go mod vendor && \
    cd ../..

ginkgo run -p \
  --timeout 2h \
  tests/rhtap -- -samplesFile "$(pwd)/extraDevfileEntries.yaml"
