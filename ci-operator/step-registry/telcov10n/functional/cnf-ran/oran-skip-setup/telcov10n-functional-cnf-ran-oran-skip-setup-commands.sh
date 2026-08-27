#!/bin/bash
set -e
set -o pipefail

if [[ "${RUN_ECO_GOTESTS_ONLY}" == "true" ]]; then
  echo "RUN_ECO_GOTESTS_ONLY=true — writing skip.txt to bypass all setup steps"
  echo "skip" > "${SHARED_DIR}/skip.txt"
else
  echo "RUN_ECO_GOTESTS_ONLY=false — setup steps will run normally"
fi
