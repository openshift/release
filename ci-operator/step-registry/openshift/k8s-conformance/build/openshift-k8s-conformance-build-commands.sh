#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GOFLAGS=""
GOBIN="${SHARED_DIR}" go install sigs.k8s.io/hydrophone@latest
