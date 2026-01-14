#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

export GOPATH=/opt/app-root
go install gotest.tools/gotestsum@latest
export PATH=${PATH}:"${GOPATH}/bin"

test-integration/hack/start-cosmos-emulator.sh
test-integration/hack/test-integration.sh
test-integration/hack/stop-cosmos-emulator.sh
