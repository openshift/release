#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

unset GOFLAGS
make lint
