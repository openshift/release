#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running the tests"
./run_tests.sh

echo "Copy logs and xunit to artifacts dir"
./copy_logs.sh "${ARTIFACT_DIR}"
