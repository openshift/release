#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

echo "************ assisted verify-generated-code command ************"

export GOCACHE=/tmp/
export GOPROXY=https://proxy.golang.org
git add . && git commit -m "initial commit after prow's substitutions & rebases"
make generate-all
git diff --exit-code  # this will fail if generate-all caused any diff
