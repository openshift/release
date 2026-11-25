#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/init-fn.sh" || true

# Ensure our random UID is in /etc/passwd; ssh-keygen fails otherwise.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

log "Generating ephemeral SSH keypair for bootstrap gather (disconnected)"
ssh-keygen -t ed25519 -N '' -C 'pext-gather' -f "${SHARED_DIR}/gather-sshkey" -q
chmod 0600 "${SHARED_DIR}/gather-sshkey"
