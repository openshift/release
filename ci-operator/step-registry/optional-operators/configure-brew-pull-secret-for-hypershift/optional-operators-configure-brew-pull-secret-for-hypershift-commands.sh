#!/bin/bash

set -o pipefail

echo "Copying the /var/run/brew-pullsecret/.dockerconfigjson file to ${SHARED_DIR}/pull-secret-build-farm.json"

# > rewrites content of ${SHARED_DIR}/pull-secret-build-farm.json
cat /var/run/brew-pullsecret/.dockerconfigjson > ${SHARED_DIR}/pull-secret-build-farm.json

echo "BREW_DOCKERCONFIGJSON has been copied"

# For hypershift clusters, ICSPs must be specified in the HostedCluster spec.
echo "ICSP file is set to ${SHARED_DIR}/operators-image-content-sources.yaml"

cat > "${SHARED_DIR}/operators-image-content-sources.yaml" << EOF
- mirrors:
  - brew.registry.redhat.io
  source: registry.redhat.io
- mirrors:
  - brew.registry.redhat.io
  source: registry.stage.redhat.io
- mirrors:
  - brew.registry.redhat.io
  source: registry-proxy.engineering.redhat.com
- mirrors:
  - brew.registry.redhat.io
  source: registry-proxy-stage.engineering.redhat.com
EOF

echo "Content to ICSP file has been copied"
