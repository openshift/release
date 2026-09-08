#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: None
EOF
