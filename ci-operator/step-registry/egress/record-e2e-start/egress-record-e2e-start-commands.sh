#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

# Capture start epoch right before running e2e tests
start_epoch=$(date +%s)
echo -n "${start_epoch}" >"${SHARED_DIR}/e2e_start_epoch"

# Also store a human-readable RFC3339 timestamp for convenience
date -u --iso-8601=seconds >"${ARTIFACT_DIR}/e2e_start_rfc3339.txt"

cat <<EOF >"${ARTIFACT_DIR}/time_window.json"
{
  "e2e_start_epoch": ${start_epoch}
}
EOF

cat "${ARTIFACT_DIR}/time_window.json"


