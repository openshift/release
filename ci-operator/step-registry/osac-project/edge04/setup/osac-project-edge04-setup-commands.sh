#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-project-edge04-setup ************"
echo "Target host: ${EDGE04_HOST}"
echo "SSH user:    ${EDGE04_USER}"

SSH_KEY_FILE="/var/run/osac-edge04-ssh-key/ssh-privatekey"

# Write the ssh_config so all subsequent steps can SSH with: ssh -F $SHARED_DIR/ssh_config ci_machine
cat > "${SHARED_DIR}/ssh_config" <<EOF
Host ci_machine
  HostName ${EDGE04_HOST}
  User ${EDGE04_USER}
  IdentityFile ${SSH_KEY_FILE}
  ConnectTimeout 10
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ServerAliveInterval 90
  LogLevel ERROR
  ConnectionAttempts 5
EOF

echo "ssh_config written:"
cat "${SHARED_DIR}/ssh_config"

echo "Verifying connectivity to ${EDGE04_HOST}..."
ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname
echo "Connection OK."
