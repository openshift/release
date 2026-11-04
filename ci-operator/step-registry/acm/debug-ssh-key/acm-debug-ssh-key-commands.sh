#!/bin/bash
set -euo pipefail

set +x
key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
ssh -V
openssl version
sha256sum "$key"
ssh-keygen -y -P '' -f "$key" >/dev/null
tail -c 1 "$key" | od -An -tx1
