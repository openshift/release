#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_remote provision "$QE_PROVISION_TIMEOUT" <<'REMOTE'
exec "$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" provision --workspace "$WORKSPACE"
REMOTE
