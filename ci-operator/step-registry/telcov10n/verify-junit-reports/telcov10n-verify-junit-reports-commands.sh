#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

# Change to eco-ci-cd directory and run the external Python script
cd /eco-ci-cd/scripts
python3 fail_if_any_test_failed.py
