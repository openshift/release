#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

status=0

echo "Running the tests"
./run_tests.sh || status="$?" || :

echo "Copy logs and xunit to artifacts dir"
./copy_logs.sh "${ARTIFACT_DIR}"

# Ensure the script returns the exit code of run_tests.sh
exit $status
