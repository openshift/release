#!/usr/bin/env bash
set -euo pipefail
umask 077

credentials=/var/run/assisted-ssh-poc
for field in ssh-privatekey ssh-hostname known-hosts; do
    if [[ ! -s "${credentials}/${field}" ]]; then
        echo "Missing SSH credential file: ${field}" >&2
        exit 1
    fi
done

SSH_HOST=$(<"${credentials}/ssh-hostname")
if [[ ! ${SSH_HOST} =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] ||
   [[ ! ${SSH_USER:-} =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    echo 'SSH hostname or user is invalid' >&2
    exit 1
fi

# The secret is mounted read-only; OpenSSH requires a private key with mode 600.
key_file=$(mktemp)
trap 'rm -f "${key_file}"' EXIT
cp "${credentials}/ssh-privatekey" "${key_file}"
chmod 600 "${key_file}"

echo "Running hostname on ${SSH_HOST}"
timeout 90s ssh -F /dev/null -T \
    -i "${key_file}" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=20 \
    -o ConnectionAttempts=1 \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=${credentials}/known-hosts" \
    "${SSH_USER}@${SSH_HOST}" hostname
