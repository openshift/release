#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_COLLECT_BASE_DIR=${ARTIFACT_DIR}

echo "Running tests..."
/opt/runTest.sh
