#!/bin/bash
set -euo pipefail
[[ -s "${SHARED_DIR}/qe-workspace" ]] || exit 0
source "${SHARED_DIR}/qe-ssh.sh"
qe_stop
status=0
qe_remote gather "$QE_GATHER_TIMEOUT" <<'REMOTE' || status=$?
mkdir -p "$WORKSPACE/public"
[[ -f "$WORKSPACE/.qe/state.json" ]] || exit 0
exec "$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" gather --workspace "$WORKSPACE"
REMOTE
work=$(cat "${SHARED_DIR}/qe-workspace")
# The runner emits only sanitized JUnit and machine-generated status/revisions.
qe_ssh "tar -C '$work/public' -cf - ." | tar -C "${ARTIFACT_DIR}" -xf - || status=1
exit "$status"
