#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export GOFLAGS='-mod=readonly'

# Run verify
cd observability
make verify

