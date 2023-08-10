#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"
git clone https://github.com/devfile/registry.git -b main && cd registry

go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo

/bin/bash tests/check_rhtap_nightly.sh
