#!/bin/bash
set -xeuo pipefail

curl https://raw.githubusercontent.com/openshift/release/master/ci-operator/step-registry/openshift/microshift/includes/openshift-microshift-includes-commands.sh -o /tmp/ci-functions.sh
# shellcheck disable=SC1091
source /tmp/ci-functions.sh
ci_script_prologue
trap_subprocesses_on_term

ssh "${IP_ADDRESS}" "\
    sudo dnf install -y pcp-zeroconf pcp-pmda-libvirt && \
    cd /var/lib/pcp/pmdas/libvirt/ && sudo ./Install &&
    sudo systemctl start pmcd && \
    sudo systemctl start pmlogger"
