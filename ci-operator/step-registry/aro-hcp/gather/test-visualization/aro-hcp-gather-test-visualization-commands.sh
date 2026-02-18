#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

test/aro-hcp-tests visualize --timing-input ${SHARED_DIR} --output ${ARTIFACT_DIR}/test-timing/

# Copy yaml files from SHARED_DIR (decompress .gz files, copy .yaml files)
for file in "${SHARED_DIR}"/timing-metadata-*.yaml*; do
    if [ -f "$file" ]; then
        if [[ "$file" == *.gz ]]; then
            gunzip -c "$file" > "${ARTIFACT_DIR}/test-timing/$(basename "${file%.gz}")"
        else
            cat "$file" > "${ARTIFACT_DIR}/test-timing/$(basename "${file}")"
        fi
    fi
done

