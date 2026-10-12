#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ netris-caas setup ************"

timeout -s 9 40m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

cd /opt/netris-test-infra
make setup-caas
EOF

echo "netris-caas setup step finished successfully"
