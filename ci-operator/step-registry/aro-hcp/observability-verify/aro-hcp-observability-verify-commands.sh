#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Run verify
cd observability
make verify

