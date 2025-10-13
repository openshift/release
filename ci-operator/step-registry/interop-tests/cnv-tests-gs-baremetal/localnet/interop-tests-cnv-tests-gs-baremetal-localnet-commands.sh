
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo uv run --verbose --cache-dir /tmp/uv-cache pytest  \
    -s \
    -o log_cli=true \
    -o cache_dir=/tmp/pytest-cache \
    --pytest-log-file "${ARTIFACT_DIR}/tests.log" \
    --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
    --junitxml "${JUNIT_RESULTS_FILE}" \
    --html="${HTML_RESULTS_FILE}" --self-contained-html \
    --tb=native \
    --tc default_storage_class:ocs-storagecluster-ceph-rbd-virtualization \
    --tc default_volume_mode:Block \
    --tc "hco_subscription:${HCO_SUBSCRIPTION}" \
    --latest-rhel \
    --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization \
    --leftovers-collector \
    -m smoke || rc=$?
