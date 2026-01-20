#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GOBIN="${SHARED_DIR}" go install sigs.k8s.io/hydrophone@latest
