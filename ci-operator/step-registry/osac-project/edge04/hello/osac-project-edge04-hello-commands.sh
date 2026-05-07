#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-project-edge04-hello ************"

ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash <<'REMOTE_EOF'
set -euo pipefail

echo "i am here" > /tmp/i_am_here
echo "File created:"
cat /tmp/i_am_here
echo "Hostname: $(hostname)"
echo "Date:     $(date)"
REMOTE_EOF

echo "Test passed — /tmp/i_am_here created on edge-04."
