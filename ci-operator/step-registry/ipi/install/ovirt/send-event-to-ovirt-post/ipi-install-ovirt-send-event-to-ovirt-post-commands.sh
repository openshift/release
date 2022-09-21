#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source ${SHARED_DIR}/ovirt-lease.conf
# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/ovirt.conf"
# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/send-event-to-ovirt.sh"

if [[ -e "${SHARED_DIR}/success" ]]; then
  send_event_to_ovirt "Success"
else
  send_event_to_ovirt "Failure"
fi