#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

echo "************ assisted verify-generated-code command ************"

export GOCACHE=/tmp/
export GOPROXY=https://proxy.golang.org

# ignore file permissions
git config core.filemode false

git add . && git commit -m "initial commit after prow's substitutions & rebases"
make generate
git diff --exit-code  # this will fail if 'make generate' caused any diff
