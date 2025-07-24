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

# Helper: get oldest available golangci-lint version. the versions used in older openshift releases can age
# out so we can try to get something as close to that as possible
get_oldest_version() {
    curl -sSfL https://api.github.com/repos/golangci/golangci-lint/releases |
        grep '"tag_name":' |
        cut -d'"' -f4 |
        grep -E '^v[0-9]+\.[0-9]+' |
        sort -V |
        head -n1
}

# get the requested version if it exists, otherwise fallback to the oldest available
if ! curl -fsSL "https://github.com/golangci/golangci-lint/releases/tag/${VERSION}" -o /dev/null; then
    echo "WARNING: golangci-lint version $VERSION not found."
    FALLBACK_VERSION=$(get_oldest_version)
    echo "Falling back to oldest available version: $FALLBACK_VERSION"
    VERSION=$FALLBACK_VERSION
fi

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