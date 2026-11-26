#!/bin/bash
set -euo pipefail
[[ -s "${SHARED_DIR}/qe-workspace" ]] || exit 0
source "${SHARED_DIR}/qe-ssh.sh"
qe_stop
work=$(cat "${SHARED_DIR}/qe-workspace")
[[ "$work" =~ ^/home/kni/prow-regression0/run\.[[:alnum:]]+$ ]]
printf -v command 'bash -s -- %q' "$work"
qe_ssh "$command" <<'REMOTE'
set -euo pipefail
work=$1
mkdir -p "$HOME/test_artifacts"
cp "$work/logs/"*.log "$HOME/test_artifacts/" 2>/dev/null || true
# Current Groovy finalCleanup has no KVM teardown. Keep VMs for debugging,
# but remove transferred vault passwords, rendered vars and per-run workspace.
sudo rm -rf -- "$work"
REMOTE
# ci-operator releases the Boskos lease after post steps, not in this script.
