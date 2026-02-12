#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

make -o tooling/templatize/templatize visualize TIMING_OUTPUT=${SHARED_DIR}/steps.yaml.gz VISUALIZATION_OUTPUT=${ARTIFACT_DIR}/timing
gunzip -c "${SHARED_DIR}/steps.yaml.gz" > "${ARTIFACT_DIR}/timing/steps.yaml"
