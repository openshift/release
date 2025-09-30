#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

frontend/hack/start-cosmos-emulator.sh
frontend/hack/test-simulation.sh
frontend/hack/stop-cosmos-emulator.sh
