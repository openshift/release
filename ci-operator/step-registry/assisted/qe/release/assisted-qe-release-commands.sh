#!/bin/bash
set -euo pipefail
[[ -s "${SHARED_DIR}/qe-workspace" ]] || exit 0
source "${SHARED_DIR}/qe-ssh.sh"
qe_stop
status=0
qe_remote cleanup "$QE_CLEANUP_TIMEOUT" <<'REMOTE' || status=$?
[[ -f "$WORKSPACE/.qe/state.json" ]] || exit 0
exec "$WORKSPACE/runner-venv/bin/python" "$WORKSPACE/ocp-edge-ci/ci/prow/runner.py" cleanup --workspace "$WORKSPACE"
REMOTE
work=$(cat "${SHARED_DIR}/qe-workspace")
[[ "$work" =~ ^/home/[a-z_][a-z0-9_-]*/prow-assisted-qe/run\.[[:alnum:]]+$ ]]
printf -v command 'bash -s -- %q' "$work"
qe_ssh "$command" <<'REMOTE' || status=1
set -euo pipefail
work=$1
# Credential removal must still run if preserving diagnostics fails, including
# bootstrap failures before noninteractive sudo was confirmed.
trap 'rm -rf -- "$work/secrets"; rm -f -- "$work/job.env"; sudo -n rm -rf -- "$work" || rm -rf -- "$work"' EXIT
# Keep diagnostics on the internal host even if reporting failed. Never retain vaults.
archive="$HOME/prow-assisted-qe/artifacts/${work##*/}"
mkdir -p "$archive"
for directory in logs results; do
    [[ ! -d "$work/$directory" ]] || sudo -n cp -r "$work/$directory" "$archive/"
done
REMOTE
# ci-operator releases the host lease after all post steps.
exit "$status"
