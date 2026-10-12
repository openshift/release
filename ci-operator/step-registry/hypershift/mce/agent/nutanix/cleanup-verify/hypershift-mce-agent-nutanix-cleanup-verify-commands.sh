#!/bin/bash

set -euo pipefail

failure_file="${SHARED_DIR}/nutanix_cleanup_failed"
if [[ -s "${failure_file}" ]]; then
  cat "${failure_file}"
  exit 1
fi

echo "Nutanix resources and temporary Squid ACL changes were cleaned up."
