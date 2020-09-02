#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo 'fips: true' > "${SHARED_DIR}/install-config.yaml"
