#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_TOKEN_CREDENTIALS=prod

unset GOFLAGS
make lint
