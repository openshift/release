#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted devscripts remotenodes command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
source "${SHARED_DIR}/ds-vars.conf"

# Copy env variables set by baremetalds-devscripts-setup to remote server
scp "${SSHOPTS[@]}" "${SHARED_DIR}/ds-vars.conf" "root@${IP}:ds-vars.conf"

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/dev-scripts.tar.gz"

# Copies pull secret to remote server
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Inject variables from the job configruation
if [[ -n "${REMOTE_NODES_CONFIG:-}" ]]; then
  readarray -t config <<< "${REMOTE_NODES_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/remote-nodes-config"
    fi
  done
fi

# Copy configuration provided by the the job, if present
if [[ -e "${SHARED_DIR}/remote-nodes-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/remote-nodes-config" "root@${IP}:remote-nodes-config"
fi

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

cd /root/dev-scripts

source /root/ds-vars.conf

# Inject job configuration, if available
if [[ -e /root/remote-nodes-config ]]
then
  source /root/remote-nodes-config
fi

bash ./remote_nodes.sh setup

echo "export REMOTE_BAREMETALHOSTS_FILE=\$REMOTE_BAREMETALHOSTS_FILE" >> /tmp/remote-vars.conf
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/tmp/remote-vars.conf" "${SHARED_DIR}/"
