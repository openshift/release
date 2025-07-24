#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# there is no container runtime in the src image so we need to run golangci-lint natively
# we can still pull the same golangci-lint VERSION and run command from whatever is currently
# in go-controller/hack/lint.sh and run exactly what would be run using 'make lint'
# below is (pulling VERSION, grabbing that specific golangci-lint, parsing the run command from
# the docker cmdline, and executing it)
cd go-controller
VERSION=$(grep '^VERSION=' hack/lint.sh | cut -d= -f2)
export VERSION
mkdir -p ../.cache/golangci-lint
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /tmp/go/bin "$VERSION"
export PATH=/tmp/go/bin:$PATH
GOLANGCI_LINT_CACHE=$(realpath ../.cache/golangci-lint)
export GOLANGCI_LINT_CACHE
export extra_flags=""
cat ./hack/lint.sh
LINT_CMD=$(awk '/golangci-lint run/ {flag=1} flag && /\\$/ {sub(/\\$/, ""); printf "%s ", $0; next} flag {print; exit}' hack/lint.sh)
export LINT_CMD
echo "$LINT_CMD"
eval "$LINT_CMD"