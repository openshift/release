#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

unset GOFLAGS
# Vendor integrity verification regenerates dependencies and requires module-proxy
# access on a cold cache, as does the go mod tidy step in make verify.
make verify-vendor
make verify
