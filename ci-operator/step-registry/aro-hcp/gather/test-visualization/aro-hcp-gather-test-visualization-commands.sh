#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace 

test/aro-hcp-tests visualize --timing-input ${SHARED_DIR} --output ${ARTIFACT_DIR}/test-timing/
cp ${SHARED_DIR}/timing-metadata-*.yaml ${ARTIFACT_DIR}/test-timing/