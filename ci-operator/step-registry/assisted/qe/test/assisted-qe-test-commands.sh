#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_remote test "$QE_TEST_TIMEOUT" <<'REMOTE'
exec "$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" test --workspace "$WORKSPACE"
REMOTE
