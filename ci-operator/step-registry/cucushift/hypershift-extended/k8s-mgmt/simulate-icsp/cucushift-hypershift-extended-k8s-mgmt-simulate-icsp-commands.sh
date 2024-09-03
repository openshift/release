#!/usr/bin/env bash

set -euxo pipefail

cat <<EOF >> "${SHARED_DIR}/mgmt_icsp.yaml"
- mirrors:
  - brew.registry.redhat.io
  source: registry.redhat.io
- mirrors:
  - brew.registry.redhat.io
  source: registry.stage.redhat.io
- mirrors:
  - brew.registry.redhat.io
  source: registry-proxy.engineering.redhat.com
EOF
