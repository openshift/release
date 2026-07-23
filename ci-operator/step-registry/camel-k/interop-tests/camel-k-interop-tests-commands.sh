#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_COLLECT_BASE_DIR=${ARTIFACT_DIR}

echo "Running tests..."
/opt/runTest.sh

# Rename xmls files to junit_*.xml
mv ${ARTIFACT_DIR}/common.xml ${ARTIFACT_DIR}/junit_common.xml
mv ${ARTIFACT_DIR}/traits.xml ${ARTIFACT_DIR}/junit_traits.xml