#!/bin/bash

set -euo pipefail

echo "=== HyperFleet Commit Message Validation ==="

if [ -z "${PULL_BASE_SHA:-}" ]; then
    echo "ERROR: PULL_BASE_SHA is not set; presubmit checks must run in PR context."
    exit 1
fi

export HOME=/tmp
export GOPATH=/tmp/go
export GOMODCACHE=/tmp/go-mod
export GOCACHE=/tmp/go-build
export PATH="$GOPATH/bin:$PATH"
unset GOFLAGS

echo "Installing hyperfleet-hooks..."
go install github.com/openshift-hyperfleet/hyperfleet-hooks/cmd/hyperfleet-hooks@v0.1.1

echo "Running commitlint validation..."
hyperfleet-hooks commitlint --pr
