#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_COLLECT_BASE_DIR=${ARTIFACT_DIR}

echo "Running tests..."
/opt/runTest.sh

echo "Adding junit prefix for xml test reports"
cd "${ARTIFACT_DIR}"
for file in *.xml
do
  mv "$file" "junit_${file}"
done
cd -