#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export NAMESPACE=$DEPL_PROJECT_NAME

echo "Running 3scale interop tests"
make smoke

echo "Copying logs and xmls to ${ARTIFACT_DIR}"
cp /test-run-results/junit-smoke.xml ${ARTIFACT_DIR}/junit_3scale_smoke.xml
cp /test-run-results/report-smoke.html ${ARTIFACT_DIR}
