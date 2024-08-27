#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

trap 'finalize' EXIT TERM INT

# Look at sos step for the exit codes definitions
function finalize()
{
  if [[ "$?" -ne "0" ]] ; then
    echo "8" >> "${SHARED_DIR}/install-status.txt"
  else
    echo "0" >> "${SHARED_DIR}/install-status.txt"
  fi
}

ssh "${IP_ADDRESS}" "\
    sudo dnf install -y pcp-zeroconf pcp-pmda-libvirt && \
    cd /var/lib/pcp/pmdas/libvirt/ && sudo ./Install &&
    sudo systemctl start pmcd && \
    sudo systemctl start pmlogger"
