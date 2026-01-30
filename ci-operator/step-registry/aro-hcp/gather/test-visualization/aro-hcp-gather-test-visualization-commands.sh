#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace 

test/aro-hcp-tests visualize --timing-input ${SHARED_DIR} --output ${ARTIFACT_DIR}/test-timing/

if ls ${SHARED_DIR}/timing-metadata-*.yaml >/dev/null 2>&1; then
    (cd ${SHARED_DIR} && tar -czf ${ARTIFACT_DIR}/test-timing/timing-metadata.tar.gz timing-metadata-*.yaml)
fi