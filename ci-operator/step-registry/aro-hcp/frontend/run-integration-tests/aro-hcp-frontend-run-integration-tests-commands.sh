#!/bin/bash
# Run race-enabled frontend integration tests with the local Cosmos emulator.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

export GOPATH=/opt/app-root
export PATH=${PATH}:"${GOPATH}/bin"
export AZURE_TOKEN_CREDENTIALS=prod
command -v gotestsum
command -v setup-envtest

test-integration/hack/start-cosmos-emulator.sh
test-integration/hack/test-integration.sh
test-integration/hack/stop-cosmos-emulator.sh
