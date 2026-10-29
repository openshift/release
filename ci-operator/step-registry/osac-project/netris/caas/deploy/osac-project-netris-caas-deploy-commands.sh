#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ netris-caas deploy ************"

timeout -s 9 80m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

cd /opt/netris-test-infra
make deploy-caas
EOF

echo "netris-caas deploy step finished successfully"
