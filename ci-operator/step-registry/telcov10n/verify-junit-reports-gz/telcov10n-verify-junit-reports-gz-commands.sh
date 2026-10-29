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

echo "Failed" >> ${SHARED_DIR}/job_status.txt

TESTS_DIR=$(mktemp -d)
export TESTS_DIR

find "${SHARED_DIR}" -name "*.tar.gz" -print0 | xargs -0 -I {} tar xvf {} -C "${TESTS_DIR}"

# Change to eco-ci-cd directory and run the external Python script
cd /eco-ci-cd/scripts
python3 fail_if_any_test_failed.py && echo "Passed" > ${SHARED_DIR}/job_status.txt

