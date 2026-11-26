#!/bin/bash
set -euo pipefail
[[ -s "${SHARED_DIR}/qe-workspace" ]] || exit 0
source "${SHARED_DIR}/qe-ssh.sh"
qe_stop
status=0
qe_remote gather "$QE_GATHER_TIMEOUT" <<'REMOTE' || status=$?
[[ -f "$WORKSPACE/results.py" ]] || exit 0
"$QE_PYTHON" "$WORKSPACE/results.py" publish "$WORKSPACE"
REMOTE
work=$(cat "${SHARED_DIR}/qe-workspace")
qe_ssh "tar -C '$work/public' -cf - ." | tar -C "${ARTIFACT_DIR}" -xf - || status=1
exit "$status"
