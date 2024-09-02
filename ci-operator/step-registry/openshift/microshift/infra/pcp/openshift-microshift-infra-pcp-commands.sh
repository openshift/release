#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_PCP_FAILURE

ssh "${IP_ADDRESS}" "\
    sudo dnf install -y pcp-zeroconf pcp-pmda-libvirt && \
    cd /var/lib/pcp/pmdas/libvirt/ && sudo ./Install &&
    sudo systemctl start pmcd && \
    sudo systemctl start pmlogger"
