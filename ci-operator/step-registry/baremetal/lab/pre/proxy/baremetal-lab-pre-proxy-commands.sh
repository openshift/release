#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping proxy configuration'
  exit
fi

# ipi-conf-proxy will run only if a specific file is found, see step code

cp "${CLUSTER_PROFILE_DIR}/proxy" "${SHARED_DIR}/proxy_private_url"

#RDU2 Lab proxy conf is applied in the previous pre-firewall step, no need to redo it here