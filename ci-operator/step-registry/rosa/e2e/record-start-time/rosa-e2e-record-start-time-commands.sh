#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

date +%s > "${SHARED_DIR}/job-start-time"
echo "Recorded job start time: $(cat "${SHARED_DIR}/job-start-time")"
