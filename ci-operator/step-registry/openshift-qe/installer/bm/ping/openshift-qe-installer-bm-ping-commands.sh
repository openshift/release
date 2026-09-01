#!/bin/bash
set -euo pipefail

remote_host=$(<"${CLUSTER_PROFILE_DIR}/remote-host")

if ping -c 5 "${remote_host}" >/dev/null 2>&1; then
  echo "Connectivity check succeeded"
else
  echo "Connectivity check failed" >&2
  exit 1
fi
