#!/bin/bash
set -euo pipefail

set +x

# No User with UID error
if ! whoami &>/dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo '/etc/passwd is not writable and the current UID has no user entry.' >&2
        exit 1
    fi
fi

key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
ssh -V
openssl version
# sha256sum "$key"
tail -c 1 "$key" | od -An -tx1
ssh-keygen -y -P '' -f "$key" >/dev/null
