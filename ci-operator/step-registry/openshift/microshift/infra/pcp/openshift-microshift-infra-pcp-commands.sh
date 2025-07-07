#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_PCP_FAILURE

if [[ -f "${SHARED_DIR}"/rebase_failure ]]; then
  echo "Rebase failed, skipping pcp"
  exit 0
fi

ssh "${IP_ADDRESS}" "\
    sudo dnf install -y pcp-zeroconf pcp-pmda-libvirt && \
    cd /var/lib/pcp/pmdas/libvirt/ && sudo ./Install &&
    sudo systemctl start pmcd && \
    sudo systemctl start pmlogger"
