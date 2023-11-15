#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"

go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo
git clone https://github.com/devfile/registry.git -b main
cd registry

# Run tests
/bin/bash tests/check_rhtap_nightly.sh
