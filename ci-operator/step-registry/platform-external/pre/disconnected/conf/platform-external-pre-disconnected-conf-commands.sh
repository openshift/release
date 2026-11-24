#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/init-fn.sh" || true

log "Generating ephemeral SSH keypair for bootstrap gather (disconnected)"
ssh-keygen -t ed25519 -N '' -C 'pext-gather' -f "${SHARED_DIR}/gather-sshkey" -q
chmod 0600 "${SHARED_DIR}/gather-sshkey"
