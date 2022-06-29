#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OpenShiftSDN
EOF

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username"