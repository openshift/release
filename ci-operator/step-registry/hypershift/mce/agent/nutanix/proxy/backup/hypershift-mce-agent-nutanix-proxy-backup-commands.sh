#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/packet-conf.sh"

if [[ -s "${SHARED_DIR}/nutanix_squid_original.conf" ]]; then
  echo "The original Squid configuration is already recorded."
  exit 1
fi

ssh "${SSHOPTS[@]}" "root@${IP}" 'test -s /root/squid.conf && cat /root/squid.conf' > "${SHARED_DIR}/nutanix_squid_original.conf"
if [[ ! -s "${SHARED_DIR}/nutanix_squid_original.conf" ]]; then
  echo "The original Squid configuration could not be saved."
  exit 1
fi
chmod 600 "${SHARED_DIR}/nutanix_squid_original.conf"
